# frozen_string_literal: true
require 'socket'
require 'open3'
require 'timeout'
require 'uri'
require_relative 'engine'

module HybridSubscription
  # Audits the installed converter against canonical nodes. Never replaces caches.
  class Converter
    LIMIT = 2 * 1024 * 1024
    DEADLINE = 20

    def initialize(base_url)
      uri = URI.parse(base_url.to_s)
      unless %w[http https].include?(uri.scheme) && %w[127.0.0.1 ::1].include?(uri.hostname) && !uri.userinfo && !uri.query && !uri.fragment
        raise Error, 'Converter must use an HTTP(S) loopback URL without credentials or query parameters'
      end
      @base_url = base_url.sub(%r{/+\z}, '')
    rescue URI::InvalidURIError
      raise Error, 'Invalid local converter URL'
    end

    def compare(nodes)
      nodes = Engine.copy(nodes)
      raise Error, 'Converter audit requires a non-empty node list' unless nodes.is_a?(Array) && !nodes.empty?
      nodes.each_with_index { |node, i| Engine.validate_node!(node, "Node #{i + 1}") }
      body = YAML.dump('proxies' => nodes)
      raise Error, 'Converter audit input exceeds 2 MiB' if body.bytesize > LIMIT
      server = TCPServer.new('127.0.0.1', 0)
      path = "/hybrid-audit-#{File.binread('/dev/urandom', 24).unpack1('H*')}.yaml"
      source_url = "http://127.0.0.1:#{server.addr[1]}#{path}"
      worker = Thread.new { serve_source(server, path, body) }
      worker.report_on_exception = false if worker.respond_to?(:report_on_exception=)
      query = URI.encode_www_form('target' => 'clash', 'list' => 'true', 'new_name' => 'true', 'emoji' => 'false',
                                 'add_emoji' => 'false', 'remove_emoji' => 'false', 'sort' => 'false', 'url' => source_url)
      result = request("#{@base_url}/sub?#{query}", DEADLINE, LIMIT)
      converted = YAML.safe_load(result, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise Error, 'Converter did not return a proxy list' unless converted.is_a?(Hash) && converted['proxies'].is_a?(Array)
      converted['proxies'].each_with_index { |node, i| Engine.validate_node!(node, "Converted node #{i + 1}") }
      answer = self.class.diff(nodes, converted['proxies'])
      begin
        version = request("#{@base_url}/version", 3, 256).strip
        answer['version'] = version if version.match?(/\Asubconverter v[0-9A-Za-z.\-]+ backend\z/)
      rescue Error
        # A failed optional version read does not invalidate an already completed audit.
      end
      answer
    rescue Psych::Exception
      raise Error, 'Converter returned invalid or unsafe YAML'
    rescue SystemCallError, IOError
      raise Error, 'Local converter audit transport failed'
    ensure
      server.close if server && !server.closed?
      if worker
        worker.kill if worker.alive?
        worker.join
      end
    end

    def self.diff(before, after)
      lists = [before, after].map do |nodes|
        raise Error, 'Audit diff requires node arrays' unless nodes.is_a?(Array)
        nodes.each_with_object({}) do |node, h|
          raise Error, 'Audit node needs a unique name' unless node.is_a?(Hash) && node['name'].is_a?(String) && !h.key?(node['name'])
          h[node['name']] = node
        end
      end
      original, converted = lists
      differences = []
      (original.keys | converted.keys).sort.each do |name|
        if !converted.key?(name)
          differences << { 'node' => name, 'kind' => 'missing', 'fields' => [] }
        elsif !original.key?(name)
          differences << { 'node' => name, 'kind' => 'added', 'fields' => [] }
        else
          fields = changed_fields(original[name], converted[name])
          differences << { 'node' => name, 'kind' => 'changed', 'fields' => fields } unless fields.empty?
        end
      end
      { 'node_count_before' => before.length, 'node_count_after' => after.length, 'differences' => differences, 'equal' => differences.empty? }
    end

    def self.changed_fields(before, after, prefix = '')
      return [] if before == after
      if before.is_a?(Hash) && after.is_a?(Hash)
        (before.keys | after.keys).sort.flat_map do |key|
          path = prefix.empty? ? key : "#{prefix}.#{key}"
          if before.key?(key) && after.key?(key)
            changed_fields(before[key], after[key], path)
          else
            [path]
          end
        end
      else
        [prefix]
      end
    end
    private_class_method :changed_fields

    private

    def request(url, timeout, limit)
      output, stderr = String.new, String.new
      Open3.popen3('curl', '--noproxy', '*', '--proto', '=http,https', '--connect-timeout', '3', '--max-time', timeout.to_s,
                  '--fail', '--silent', '--show-error', url) do |input, stdout, errors, wait|
        input.close
        begin
          Timeout.timeout(timeout + 1) do
            streams = [stdout, errors]
            until streams.empty?
              ready = IO.select(streams, nil, nil, timeout)
              raise Error, 'Local converter request timed out' unless ready
              ready[0].each do |io|
                chunk = io.read_nonblock(16_384, exception: false)
                if chunk.nil?
                  streams.delete(io)
                elsif chunk != :wait_readable
                  if io == stdout
                    output << chunk
                    raise Error, 'Converter response exceeds its size limit' if output.bytesize > limit
                  else
                    stderr << chunk if stderr.bytesize < 1024
                  end
                end
              end
            end
            raise Error, 'Local converter request failed' unless wait.value.success?
          end
        rescue Timeout::Error
          raise Error, 'Local converter request timed out'
        ensure
          if wait.alive?
            Process.kill('TERM', wait.pid) rescue nil
            unless wait.join(0.2)
              Process.kill('KILL', wait.pid) rescue nil
              wait.join
            end
          end
        end
      end
      output
    rescue Errno::ENOENT
      raise Error, 'curl is required for the local converter audit'
    end

    def serve_source(server, path, body)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
      4.times do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0 || !IO.select([server], nil, nil, remaining)
        client = server.accept
        begin
          header = String.new
          connection_deadline = [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3].min
          until header.include?("\r\n\r\n")
            break if header.bytesize > 8192
            left = connection_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if left <= 0 || !IO.select([client], nil, nil, left)
            chunk = client.read_nonblock(1024, exception: false)
            break if chunk.nil?
            header << chunk unless chunk == :wait_readable
          end
          method, requested, protocol = header.lines.first.to_s.strip.split(' ', 3)
          valid = header.bytesize <= 8192 && header.include?("\r\n\r\n") && %w[HTTP/1.0 HTTP/1.1].include?(protocol)
          code = valid && method == 'GET' && requested == path ? '200 OK' : (method == 'GET' ? '404 Not Found' : '405 Method Not Allowed')
          payload = code == '200 OK' ? body : ''
          response = "HTTP/1.1 #{code}\r\nContent-Type: application/yaml\r\nContent-Length: #{payload.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n#{payload}"
          offset = 0
          while offset < response.bytesize
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if left <= 0 || !IO.select(nil, [client], nil, left)
            written = client.write_nonblock(response.byteslice(offset, 16_384), exception: false)
            offset += written if written.is_a?(Integer)
          end
          break if code == '200 OK'
        rescue SystemCallError, IOError
          # Each connection is bounded and rejected without logging its contents.
        ensure
          client.close rescue nil
        end
      end
    rescue SystemCallError, IOError
      nil
    end
  end
end

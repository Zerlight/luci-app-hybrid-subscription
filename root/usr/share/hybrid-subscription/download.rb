# frozen_string_literal: true
require_relative 'backend'
module HybridSubscription
  class Download
    def initialize(backend); @b=backend; end
    def equal?(a,b)
      return false unless a.is_a?(String) && b.is_a?(String) && a.bytesize==b.bytesize && !a.empty?
      a.bytes.zip(b.bytes).reduce(0) { |r,(x,y)| r | (x^y) } == 0
    end
    def local?(address)
      ip=IPAddr.new(address); ip=ip.native if ip.ipv4_mapped?
      return true if IPAddr.new('127.0.0.0/8').include?(ip) || ip==IPAddr.new('::1')
      n=JSON.parse(@b.command(['ubus','call','network.interface.lan','status'],seconds:3))
      nets=Array(n['ipv4-address'])+Array(n['ipv6-address'])
      Array(n['ipv6-prefix-assignment']).each { |p| nets << p }
      nets.any? do |a|
        begin; IPAddr.new(a.fetch('address')+'/'+a.fetch('mask').to_s).include?(ip)
        rescue StandardError; false; end
      end
    rescue StandardError
      false
    end
    def session?(cookie)
      cookies=cookie.to_s.split(';').map { |x| x.strip.split('=',2) }.to_h
      sid=cookies['sysauth_https'] || cookies['sysauth_http'] || cookies['sysauth']
      return false unless sid.to_s.match?(/\A[a-f0-9]{32}\z/)
      args={'ubus_rpc_session'=>sid,'scope'=>'ubus','object'=>'luci.hybrid_subscription','function'=>'download_info'}
      JSON.parse(@b.command(['ubus','call','session','access',JSON.generate(args)],seconds:3))['access']==true
    rescue StandardError
      false
    end
    def response(env)
      method=env.fetch('REQUEST_METHOD','GET')
      return [405,{},'Method not allowed'] unless %w[GET HEAD].include?(method)
      query=env.fetch('QUERY_STRING','')
      return [400,{},'Invalid request'] if query.bytesize>2048
      pairs=URI.decode_www_form(query)
      return [400,{},'Duplicate parameters'] unless pairs.map(&:first).uniq.length==pairs.length
      q=pairs.to_h; id=@b.check_id(q['profile']); fmt=q['format']; @b.filename(fmt)
      c=@b.config; mode=c['settings']['access_mode']
      allowed=if mode=='session'
        session?(env['HTTP_COOKIE'])
      else
        token=@b.read(@b.path('tokens.json'))[id]
        equal?(q['token'],token) && (mode=='token' || (mode=='lan_token' && local?(env.fetch('REMOTE_ADDR',''))))
      end
      return [403,{},'Access denied'] unless allowed
      rid=@b.published[id]; return [404,{},'No published subscription'] unless rid
      meta=@b.release_meta(rid); return [404,{},'Format not published'] unless meta.fetch('formats',[]).include?(fmt)
      file=File.join(@b.release_path(rid),@b.filename(fmt))
      content=File.binread(file)
      return [503,{},'Published file verification failed'] unless Digest::SHA256.hexdigest(content)==meta['sha256'][fmt]
      update=meta.fetch('client_update',{})
      headers={}
      if update['enabled']==true && mode!='session'
        if fmt=='surge'
          begin
            url=@b.client_update_url(c['settings'],id,fmt,token)
          rescue HybridSubscription::Error
            return [503,{},'Client update URL is not configured or invalid']
          end
          content="#!MANAGED-CONFIG #{url} interval=#{update.fetch('interval')*3600} strict=false\n"+content
        elsif fmt=='mihomo'
          headers['Profile-Update-Interval']=update.fetch('interval').to_s
        end
      end
      type={'mihomo'=>'application/yaml; charset=utf-8','surge'=>'text/plain; charset=utf-8','singbox'=>'application/json; charset=utf-8','shadowrocket'=>'application/yaml; charset=utf-8'}[fmt]
      headers.merge!('Content-Type'=>type,'Content-Disposition'=>"attachment; filename=\"#{id}-#{@b.filename(fmt)}\"",'Content-Length'=>content.bytesize.to_s,'ETag'=>'"'+Digest::SHA256.hexdigest(content)+'"')
      [200,headers,method=='HEAD' ? '' : content]
    rescue StandardError
      [400,{},'Invalid request']
    end
  end
end
if $PROGRAM_NAME==__FILE__
 begin
  status,headers,body=HybridSubscription::Download.new(HybridSubscription::Backend.new).response(ENV)
 rescue StandardError
  status,headers,body=503,{},'Subscription service unavailable'
 end
 reason={200=>'OK',400=>'Bad Request',403=>'Forbidden',404=>'Not Found',405=>'Method Not Allowed',503=>'Service Unavailable'}[status]
 headers={'Content-Type'=>'text/plain; charset=utf-8','Cache-Control'=>'no-store','X-Content-Type-Options'=>'nosniff','Referrer-Policy'=>'no-referrer'}.merge(headers)
 STDOUT.binmode
 STDOUT.write("Status: #{status} #{reason}\r\n")
 headers.each { |k,v| STDOUT.write("#{k}: #{v}\r\n") }
 STDOUT.write("\r\n")
 STDOUT.write(body)
end

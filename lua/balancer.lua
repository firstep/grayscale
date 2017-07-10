--[[
    desc    :动态负载服务列表
    author  :firstep@qq.com
    date    :20170609
]]

--STEP.1 获取当前upstream的名称，并确定是否灰度账号，获取下一个负载节点
local streamType = ngx.var.ups;
local user = ngx.req.get_headers()["username"];

local peer, err = server.next_peer(streamType, user)
if not peer then
    ngx.log(ngx.ERR, "failed to select next peer: ", err)    
    return ngx.exit(500)
end

--STEP.2 转到选定的服务
local ok, err = balancer.set_current_peer(peer[1], peer[2])
if not ok then
    ngx.log(ngx.ERR, "failed to set the current peer: ", err)    
    return ngx.exit(500)
end

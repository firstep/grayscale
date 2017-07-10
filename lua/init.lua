--[[
    desc    :初始化
    author  :firstep@qq.com
    date    :20170609
]]

ngx.log(ngx.INFO, "init: ", "init something...")

--STEP.1 加载所需要的模块，并赋值到全局变量
cjson		= require "cjson"
balancer	= require "ngx.balancer"
config		= require "firstep.config"
auth 		= require "firstep.wsse_auth"
server		= require "firstep.server"

local ok, err = config:reload()
if not ok then
    error("init config failed: " .. err)
end
--[[
    desc    :对外提供api
    author  :firstep@qq.com
    date    :20170609
]]


local uri = ngx.var.uri;
local method = ngx.req.get_method()

local function err_msg(err)
    local ret = {result = "faild", reason = err}
    return cjson.encode(ret)
end

local function check_server_body(data)
    if data.gray == nil then
        ngx.say(err_msg("params [gray] is require."))
        return nil
    end

    if data.upstream == nil then
        ngx.say(err_msg("params [upstream] is require."))
        return nil
    end

    if data.servers == nil then
        ngx.say(err_msg("params [servers] is require."))
        return nil
    end

    if type(data.servers) ~= "table" then
        ngx.say(err_msg("params [servers] is not array."))
        return nil
    end
    return true
end

if "/servers" == uri then       --服务设置接口
    if "GET" == method then
        ngx.say(server.get_servers());
    elseif "POST" == method or "DELETE" == method then
        local raw = ngx.ctx["body_raw"];
        local ok, data = pcall(cjson.decode, raw)
        if not ok then
            ngx.say(err_msg("param is invalid: " .. data))
            return
        end

        local ok = check_server_body(data)
        if not ok then
            return
        end

        --FIXME 验证服务列表格式是否正确

        local ok, err
        if "POST" == method then
            ok, err = server.add_server(data.gray, data.upstream, data.servers, true)
        else
            ok, err = server.del_server(data.gray, data.upstream, data.servers)
        end

        if ok then
            ngx.say([[{"result":"success"}]])
        else            
            ngx.say(err_msg(err))
        end
    else
        ngx.exit(ngx.HTTP_NOT_ALLOWED)
    end
elseif "/servers/switch" == uri and "POST" == method then    --接口切换
    local raw = ngx.ctx["body_raw"];
    local ok, data = pcall(cjson.decode, raw)
    if not ok then
        ngx.say(err_msg("param is invalid: " .. data))
        return
    end

    local ok = check_server_body(data)
    if not ok then
        return
    end

    local ok, err = server.switch_server(data.gray, data.upstream, data.servers)
    if not ok then
        ngx.log(ngx.ERR, "add node faild: ", err)
        ngx.say(err_msg("switch node faild."))
        return
    else
        ngx.say([[{"result":"success"}]])
    end

elseif "/users" == uri then     --用户设置接口
    if "GET" == method then
        ngx.say(server.get_users());
    elseif "POST" == method or "DELETE" == method then
        local raw = ngx.ctx["body_raw"];
        local ok, data = pcall(cjson.decode, raw)
        if not ok then
            ngx.say(err_msg("param is invalid: " .. data))
            return
        end

        if type(data) ~= "table" then
            ngx.say(err_msg("param is not array"))
            return 
        end

        local ok, err
        if "POST" == method then
            ok, err = server.add_user(data)
        else
            ok, err = server.del_user(data)
        end

        if ok then
            ngx.say([[{"result":"success"}]])
        else
            ngx.say(err_msg(err))
        end
    else
        ngx.exit(ngx.HTTP_NOT_ALLOWED)
    end
else
    ngx.exit(ngx.HTTP_NOT_ALLOWED)
end

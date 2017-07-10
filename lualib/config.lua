--[[
    desc    :服务配置类
    author  :firstep@qq.com
    date    :20170609
]]

local shared = ngx.shared

-- 初始化全局缓存dict
local cfg_dict = shared["config"]
if not cfg_dict then
    error("shared key \"config\" not found.")
end

local ok, configurable = pcall(require, "firstep.configurable")
if not ok then
    error("configurable module required")
end
----------------------------------------------------------


--========================================================================
--
--              对外提供的服务方法
--
--========================================================================

local _M = {
    _VERSION = '0.01',
    cfg_dict = cfg_dict,
    cfg_path = "../conf/config.json",      -- 文件的erveyone的写权限需设置
    chg_flag_key = "CHG_FLAG_FOR_SRV",     -- 配置对象更改标志key
    cfg_key = "config",                    -- 配置文件源文本在shared中的key
    m_clients = nil
}

setmetatable(_M, {__index = configurable})    --继承自configurable

function _M.get_config(key)
    return _M.m_cfg[key]
end

function _M.get_servers(key)
    if key == nil then
        return _M.m_cfg.servers
    else
        return _M.m_cfg.servers[key]
    end
end

function _M.get_users(key)
    if key == nil then
        return _M.m_cfg.users
    else
        return _M.m_cfg.users[key]
    end
end

function _M.get_auth()
    return _M.m_cfg.auth;
end

function _M.get_auth_clients()
    return _M.m_clients;
end

function _M.get_balance_policy()
    return _M.m_cfg["balance_policy"];
end

--复写父类的reload
function _M:reload()
    local ok, err = getmetatable(self).__index.reload(self)
    if not ok then
        return ok, err
    end

    --把client复写为map方式放在成员变量中
    local clients = self.m_cfg["auth"]["clients"]
    if clients == nil then
        return nil, "not found clients item."
    end
    self.m_clients = nil
    self.m_clients = {}
    for i,v in ipairs(clients) do
        self.m_clients[v] = true
    end

    ngx.log(ngx.DEBUG, "reload auth config: ", cjson.encode(self.m_clients))

    return true
end

return _M

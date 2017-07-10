--[[
    desc    :可持久化的配置父类，抽象整个配置读取和覆盖过程
    author  :firstep@qq.com
    date    :20170609
]]

local debug_mode = ngx.config.debug

-- 加载fii
local ok, ffi = pcall(require, "ffi")
if not ok then
    error("ffi module required")
end

ffi.cdef[[
    struct timeval {
        long int tv_sec;
        long int tv_usec;
    };
    int gettimeofday(struct timeval *tv, void *tz);
]]

local tm = ffi.new("struct timeval")

local function errlog( ... )
    ngx.log(ngx.ERR, "config: ", ...)
end

local function debug( ... )
    if debug_mode then
        ngx.log(ngx.DEBUG, "config: ", ...)
    end
end

local function get_time_millis()
    ffi.C.gettimeofday(tm, nil)
    local sec =  tonumber(tm.tv_sec)
    local usec =  tonumber(tm.tv_usec)
    return sec + usec * 10^-6;
end

local function read_config(path)
    local file = io.open(path, "r")
    if file == nil then
        return false, "Load file failed."
    end
    local data = file:read("*a")   --读取所有
    file:close()

    return true, data
end

local function save_config(path, text)
    local file, err = io.open(path, "w")
    if file == nil then
        return false
    else
        file:write(text)
        file:close()
        return true
    end
end

local _M = {
    cfg_path = "",
    chg_flag_key = "",
    curr_chg_flag = "",
    cfg_key = "",
    cfg_dict = nil,
    m_cfg = nil
}

function _M:flush()
    debug("flush_config...")
    if(self.m_cfg == nil) then
        return false, "object config is null" 
    end
    local cfg_srt = cjson.encode(self.m_cfg);
    local ok = save_config(self.cfg_path, cfg_srt)

    if ok then
        self:notify()
        return self.cfg_dict:set(self.cfg_key, cfg_srt)
    else
        self:reload()
        return false, "save config file failed."
    end
end

function _M:reload()
    debug("load config: " .. self.cfg_path)
    local cfg_str = self.cfg_dict:get(self.cfg_key)
    if not cfg_str then
        debug("load config from file...")
        local ok, data = read_config(self.cfg_path)
        if not ok then
            return false, data
        end

        cfg_str = data

        local suc,err,forcible = self.cfg_dict:set(self.cfg_key, data)
        if not suc then
            return false, "set data["..data.."] to sharedDIC error:"..err
        else
            ngx.log(ngx.INFO, "init local config success:"..data)
        end
    end

    self.m_cfg = cjson.decode(cfg_str)
    return true

end

function _M:notify()
    local flag = tostring(get_time_millis())
    local ok, err = self.cfg_dict:set(self.chg_flag_key, flag)
    if not ok then
        errlog("key: cfg_change not found, ", err)
        return ok, err
    end
    self.curr_chg_flag = flag
    return true
end

function _M:init()
    debug("init config.")

    --避免配置在多个阶段都执行判断
    if ngx.ctx["init:" .. self.chg_flag_key] then
        return true
    else
        ngx.ctx["init:" .. self.chg_flag_key] = true
    end

    local flag = self.cfg_dict:get(self.chg_flag_key)
    if flag and (self.curr_chg_flag ~= flag) then
        self.curr_chg_flag = flag
        self:reload()
    end

    return true
end

function _M:test()
    ngx.say(self.cfg_path)
    ngx.say(cjson.encode(self.m_cfg))
end

return _M
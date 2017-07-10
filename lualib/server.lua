--[[
    desc    :服务配置类
    author  :firstep@qq.com
    date    :20170609
]]

local IDX_HOST = 1;
local IDX_PORT = 2;
local IDX_LIVE = 3;
local IDX_WEIGHT = 4;

local POLICY_DEFAULT        = 0;
local POLICY_WEIGHT         = 1;
local POLICY_IPHASH         = 2;

--========================================================================
--
--              工具方法
--
--========================================================================
local function comp(v1, v2, is_array)
    if is_array then
        return v1[IDX_HOST] == v2[IDX_HOST] and v1[IDX_PORT] == v2[IDX_PORT]
    else
        return v1 == v2
    end
end

local function merge(dest, src, is_array)
    local find = false;
    for i, v in pairs(src) do
        find = false;
        for j, _v in pairs(dest) do
            if comp(v, _v, is_array) then
                --把live状态及权重合并
                if is_array then
                    if v[IDX_LIVE] ~= nil then
                        _v[IDX_LIVE] = v[IDX_LIVE]
                    end
                    if v[IDX_WEIGHT] ~= nil and v[IDX_WEIGHT] > 0 then
                        _v[IDX_WEIGHT] = v[IDX_WEIGHT]
                    end
                end
                find = true;
                break;
            end
        end
        if find == false then
            if is_array then
                if v[IDX_LIVE] == nil then
                    v[IDX_LIVE] = true
                end
                if v[IDX_WEIGHT] == nil then
                    v[IDX_WEIGHT] = 1
                end
            end
            table.insert(dest, v)
        end
    end
end

local function remove(dest, src, is_array)
    for i, v in pairs(src) do
        --逆向遍历
        for j = #dest, 1, -1 do
            if comp(v, dest[j], is_array) then
                table.remove(dest, j)
                break;
            end
        end
    end
end

-- 在目标数组中能找到一个就算ok
local function contains(array, val, is_array)
    for _,v in ipairs(array) do
        if comp(v, val, is_array) then
            return true
        end
    end
    return false
end

local function modify(dest, src, is_array, is_add)
    if is_add then
        merge(dest, src, is_array)
    else
        remove(dest, src, is_array)
    end
end

--========================================================================
--
--              负载算法
--
--========================================================================
local function weighted_round_robin(peers)
    local host
    local weight = 0
    local total = 0
    local best_weight = 0
    local best_peer = nil
    local best_host
    for i,peer in ipairs(peers) do
        if peer[IDX_LIVE] == true then
            weight = peer[IDX_WEIGHT] or 1
            total = total + weight

            host = "cw:" .. peer[IDX_HOST] .. ":" .. peer[IDX_PORT]
            local curr_weight, err = cfg_dict:incr(host, weight, 0)

            if best_peer == nil or curr_weight > best_weight then
                best_peer = peer
                best_weight = curr_weight
                best_host = host
            end
        end
    end

    if best_peer == nil then
        return nil, "not selected."
    end
    cfg_dict:incr(best_host, total * -1)
    return best_peer
end

local function round_robin(key, len)
    local v,err = cfg_dict:incr(key, 1, 0);
    local ret = (v % len) + 1;
    if ret == 1 then
        cfg_dict:set(key, 0)
    end
    return ret;
end

local function get_real_ip()
    local ip = ngx.req.get_headers()["X-Real-IP"]
    if ip == nil then
        ip = ngx.req.get_headers()["x_forwarded_for"]
    end
    if ip == nil then
        ip = ngx.var.remote_addr
    end
    return ip;
end

local function ip_hash(key, len)
    local ip = get_real_ip()
    local hash = ngx.crc32_long(ip .. key)
    hash = (hash % len) + 1
    return hash;
end

--========================================================================
--
--              对外提供的服务方法
--
--========================================================================

local _M = {_VERSION = '0.01'}

-- 获取所有服务节点
function _M.get_servers()
    local tab = {normal = config.get_servers("normal"), gray = config.get_servers("gray")}
    return cjson.encode(tab)
end

-- 获取指定upstream所有节点
function _M.get_peers(is_gray, upstream)
    local kind = is_gray and "gray" or "normal"
    return config.get_servers()[kind][upstream]
end

-- 获取指定upstream存活的服务
function _M.get_up_peers(is_gray, upstream)
    local peers = _M.get_peers(is_gray, upstream)
    if not peers then
        return peers
    end

    local ret = {}
    for _,v in ipairs(peers) do
        if v[IDX_LIVE] then
            table.insert(ret, v)
        end
    end
    if #ret == 0 then
        return nil
    else
        return ret
    end
end

--新增或修改服务
function _M.add_server(is_gray, upstream, array, valid)
    if valid then
        local _peers = _M.get_peers(not is_gray, upstream)
        if not _peers then
            return nil, "kind of peer \"" ..upstream .. ":"..tostring(is_gray).."\" not found."
        end
        for _,v in ipairs(array) do
            if contains(_peers, v, true) then
                return nil, "this host[" .. v[1] .. ":" .. v[2] .. "] is exist, statu is " .. (is_gray and "normal" or "gray")
            end
        end
    end

    local peers = _M.get_peers(is_gray, upstream)
    if not peers then
        return nil, "kind of peer \"" ..upstream .. ":"..tostring(is_gray).."\" not found."
    end

    modify(peers, array, true, true)
    return config:flush()
end

-- 删除服务
function _M.del_server(is_gray, upstream, array)
    local peers = _M.get_peers(is_gray, upstream)
    if not peers then
        return nil, "kind of peer \"" ..upstream .. ":"..tostring(is_gray).."\" not found."
    end

    modify(peers, array, true, false)
    return config:flush()
end

-- 服务节点在灰度和正常节点中转换
function _M.switch_server(is_gray, upstream, array)
    local ok, err = _M.add_server(not is_gray, upstream, array)
    if not ok then
        return nil, err
    end
    local ok, err = _M.del_server(is_gray, upstream, array)
    if not ok then
        return nil, err
    end
    return true
end

-- 获取所有的灰度用户列表
function _M.get_users()
    return cjson.encode(config.get_users())
end

-- 增加灰度账号
function _M.add_user(array)
    modify(config.get_users(), array, false, true)
    return config:flush()
end

-- 删除灰度用户
function _M.del_user(array)
    modify(config.get_users(), array, false, false)
    return config:flush()
end

-- 以轮训的方式获取下个负载节点
function _M.next_peer(upstream, username)
    local is_gray = username and contains(config.get_users(), username, false)
    local peers = _M.get_up_peers(is_gray, upstream)
    if not peers then
        return nil, "kind of peer \"" ..upstream .. ":"..tostring(is_gray).."\" not found."
    end

    local size = #peers
    if size == 1 then
        return peers[1]
    end

    local curr_policy = config.get_balance_policy()
    local peer
    if POLICY_WEIGHT == curr_policy then
        peer = weighted_round_robin(peers)
    elseif POLICY_IPHASH == curr_policy then
        local index = ip_hash("rr:"..(is_gray and "1" or "0")..upstream, size)
        peer = peers[index]
    else
        local index = round_robin("rr:"..(is_gray and "1" or "0")..upstream, size)
        peer = peers[index]
    end

    if peer then
    	ngx.log(ngx.DEBUG, "config: ", "select next peer, user:"..(username or "nil").." upstream:"..upstream.." gray:"..tostring(is_gray).." peer:"..peer[1]..":"..peer[2])
    end
    return peer
end

return _M
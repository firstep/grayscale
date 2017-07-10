--[[
    desc    :upstream健康检查类
    author  :firstep@qq.com
    date    :20170228
]]

local new_timer = ngx.timer.at
local shared = ngx.shared
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local stream_sock = ngx.socket.tcp
local re_find = ngx.re.find
local sub = string.sub

local GRAY_PEER = true
local NORMAL_PEER = false

local IDX_HOST = 1;
local IDX_PORT = 2;
local IDX_LIVE = 3;

g_need_flush = false    --用于标记，当前定时检查做完后，是否需要flush配置到配置文件

local _M = {}

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local function debug( ... )
    ngx.log(ngx.DEBUG, "healthcheck: ", ...)
end

local function errlog( ... )
    ngx.log(ngx.ERR, "healthcheck: ", ...)
end

local function peer_err(ctx, peer, ...)
    local peer_live = peer[IDX_LIVE]

    debug("check result: failed live: "..tostring(peer_live))
    if peer_live then
        errlog(...)
    else
        return --本来就是下线的就不再继续了
    end

    local peer_name = peer[IDX_HOST] .. ":" .. tostring(peer[IDX_PORT])
    local key = "down:" .. peer_name

    local count, err = ctx.dict:incr(key, 1, 0)
    if not count then
        errlog("failed to set peer down key: ", key, " err: ", err)
        return
    end

    debug("peer: ", key, " fail count: ", count)

    if count >= ctx.fall then
        debug("peer: ", key, " will down.")
        ctx.dict:delete(key)
        peer[IDX_LIVE] = false
        g_need_flush = true
    end
end

local function peer_ok(ctx, peer)
    local peer_live = peer[IDX_LIVE]
    debug("check result: ok live: "..tostring(peer_live))

    if peer_live then
        return    --本来存活的服务就不再继续了
    end
    local peer_name = peer[IDX_HOST] .. ":" .. tostring(peer[IDX_PORT])
    local key = "rise:" .. peer_name

    local count, err = ctx.dict:incr(key, 1, 0)
    if not count then
        errlog("failed to set peer up key: ", key, " err: ", err)
        return
    end

    debug("peer: ", key, " success count: ", count)

    if count >= ctx.rise then
        debug("peer: ", key, " will up.")
        ctx.dict:delete(key)
        peer[IDX_LIVE] = true
        g_need_flush = true
    end
end

local function check_peer(ctx, peer)
    local ok, err
    local req = ctx.http_req
    local statuses = ctx.statuses
    local peer_name = peer[IDX_HOST] .. ":" .. tostring(peer[IDX_PORT])
    debug("do checking peer: ".. peer_name)

    local sock, err = stream_sock()
    if not sock then
        errlog("failed to create stream socket", err)
        return
    end

    sock:settimeout(ctx.timeout)

    ok, err = sock:connect(peer[IDX_HOST], peer[IDX_PORT])

    if not ok then
        return peer_err(ctx, peer, 
            "failed to connect to ", peer_name, " : ", err)
    end

    local bytes, err = sock:send(req)
    if not bytes then
        return peer_err(ctx, peer, 
            "failed to send request to ", peer_name, " : ", err)
    end

    local status_line, err = sock:receive()
    if not status_line then
        peer_err(ctx, peer, 
                    "failed to receive status line from ", peer_name, " : ", err)
        if err == "timeout" then
            sock:close()
        end
        return
    end

    if statuses then
        local from, to, err = re_find(status_line,
                              [[^HTTP/\d+\.\d+\s+(\d+)]],
                              "joi", nil, 1)
        if not from then
            peer_err(ctx, peer, 
                    "bad status line from ", peer_name, " : ", status_line)
            sock:close()
            return
        end

        local status = tonumber(sub(status_line, from, to))
        if not statuses[status] then
            peer_err(ctx, peer, 
                    "bad status code from ", peer_name, " : ", status)
            sock:close()
            return
        end
    end

    peer_ok(ctx, peer)
    sock:close()
end

local function check_peer_range(ctx, from, to, peers)
    for i = from, to do
        check_peer(ctx, peers[i])
    end
end

local function check_peers(ctx, peers)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i=1, n do
            check_peer(ctx, peers[i])
        end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do
                debug("spawn a thread checking", " peer ", i - 1)
                threads[i] = spawn(check_peer, ctx, peers[i])
            end

            debug("check peer ", n - 1)
            check_peer(ctx, peers[n])
        else
            local group_size = math.ceil(n / concur)
            local nthr = math.ceil(n / group_size) - 1

            threads = new_tab(nthr, 0)
            local from = 1
            local to
            for i = 1, nthr do
                to = from + group_size -1

                debug("spawn a thread checking peers ", from -1, " to ", to - 1)

                threads[i] = spawn(check_peer_range, ctx, from, to, peers)

                from = from    + group_size
            end

            if from <= n then
                to = n
                debug("spawn a thread checking peers ", from -1, " to ", to - 1)

                check_peer_range(ctx, from, to, peers)
            end
        end

        --等待线程结束
        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then
                    wait(t)
                end
            end
        end
    end

    debug("check peers done.")
end

local function get_lock(ctx)
    local dict = ctx.dict
    local key = "l:" .. ctx.upstream
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            debug("key " .. key .. " is exists.")
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

local function do_check(ctx)
    debug("run a check cycle")

    if not get_lock(ctx) then
        debug("no lock exit.")
        return
    end

    debug("get lock...")

    g_need_flush = false
    config:init()

    local normal_peers    = config.get_peers(NORMAL_PEER, ctx.upstream)
    if not normal_peers then
        return nil, "not found normal peers"
    end
    local gray_peers    = config.get_peers(GRAY_PEER, ctx.upstream)
    if not gray_peers then
        return nil, "not found gray peers"
    end

    --debug(config.get_servers())

    check_peers(ctx, normal_peers)
    check_peers(ctx, gray_peers)

    if g_need_flush then
        local ok, err = config:flush()
        if not ok then
            errlog("flush config fail: ", err)
            return false, err
        end
    end
    debug("all check done.")
    return true
end

local check
check = function(premature, ctx)
    if premature then
        return
    end

    local ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run healthcheck cycle:", err)
    end

    local ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end
    end
end

function _M.spawn_checker(opts)
    local http_req = opts.http_req
    if not http_req then
        return nil, "\"http_req\" option required"
    end

    local timeout = opts.timeout or 1000
    local interval = opts.interval
    if not interval then
        interval = 1
    else
        interval = interval / 1000
        if interval < 0.002 then
            interval = 0.002
        end
    end

    local fall = opts.fall or 4

    local rise = opts.rise or 2

    local valid_statuses = opts.valid_statuses
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _,v in ipairs(valid_statuses) do
            statuses[v] = true
        end
    end

    local concur = opts.concurrency or 1
    local key = opts.key
    if not key then
        return nil, "\"key\" option required"
    end

    local dict = shared[key]
    if not dict then
        return nil, "key \"" .. tostring(key) .. " \" not found"
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    local ctx = {
        upstream = u,                -- 当前检查的upstream
        http_req = http_req,        -- 请求体
        timeout = timeout,            -- 检查超时时间
        interval = interval,        -- 执行间隔
        fall = fall,                -- 服务累积错误次数达到时把服务down
        rise = rise,                -- 服务累积成功次数达到把服务up
        dict = dict,                -- 健康检查所需要的缓存
        statuses = statuses,        -- 验证通过的状态码列表
        concurrency = concur         -- 最大线程并发数
    }

    local ok, err = new_timer(0, check, ctx)
    if not ok then
        return nil, "failed to create timmer:" .. err
    end

    return true
end

return _M

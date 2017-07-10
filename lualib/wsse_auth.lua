--[[
    desc    :access阶段进行WS-SE验证
    author  :firstep@qq.com
    date    :20170609
]]

local hmac = require "firstep.hmac"
local resty_sha256 = require "resty.sha256"
local base64 = require "resty.core.base64"
local str = require "resty.string"
local re_find = ngx.re.find
local sub = string.sub

--========================================================================
--
--              工具方法
--
--========================================================================

-- 生成appkey和appsecret的密文
local function gen_pwd_digest(secret_key, nonce, created)
    local sha256 = resty_sha256:new()
    sha256:update(tostring(nonce) .. tostring(created) .. secret_key)
    local digest = sha256:final()
    return ngx.encode_base64(digest)
end

-- 生成postbody的签名
local function gen_body_sign(key, raw_body)
    local hmac_sha256 = hmac:new(key, hmac.ALGOS.SHA256)
    if not hmac_sha256 then
        return nil, "failed to create the hmac_sha256 object"
    end
    hmac_sha256:update(raw_body)
    local digest = hmac_sha256:final()
    return ngx.encode_base64(digest)
end

local function parse_realm()
    local text = ngx.req.get_headers()["Authorization"]
    if not text then
        return nil, [[http request header "Authorization" is not found]]
    end

    local from, to = re_find(text,[[realm="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, [[header "Authorization" can't found realm.]]
    end
    return sub(text, from, to)
end

local function parse_username_token()
    local token = ngx.req.get_headers()["X-WSSE"]
    if not token then
        return nil, nil, nil, nil, [[http request header "X-WSSE" is not found]]
    end
    local from, to = re_find(token,[[Username="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, nil, nil, nil, [[header "X-WSSE" can't found username.]]
    end
    local uname = sub(token, from, to)

    local from, to = re_find(token,[[PasswordDigest="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, nil, nil, nil, [[header "X-WSSE" can't found PasswordDigest.]]
    end
    local pwd_digest = sub(token, from, to)

    local from, to = re_find(token,[[Nonce="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, nil, nil, nil, [[header "X-WSSE" can't found Nonce.]]
    end
    local nonce = sub(token, from, to)

    local from, to = re_find(token,[[Created="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, nil, nil, nil, [[header "X-WSSE" can't found Created.]]
    end
    local created = sub(token, from, to)

    return uname, nonce, created, pwd_digest
end

local function parse_sign_body()
    local token = ngx.req.get_headers()["Body-Sign"]
    if not token then
        return nil, [[http request header "Body-Sign" is not found]]
    end
    local from, to = re_find(token,[[signature="([^"]+)"]], "joi", nil, 1)
    if from == nil or to == nil then
        return nil, [[header "Body-Sign" can't found signature.]]
    end
    local signature = sub(token, from, to)
    return signature
end

--========================================================================
--
--              对外提供的服务方法
--
--========================================================================

local _M = {}

function _M.run()

	local ok, err = _M.check_realm()
	if not ok then
	    ngx.log(ngx.DEBUG, "auth faild: ", err)
	    return ngx.exit(ngx.HTTP_UNAUTHORIZED)
	end

	local app_key, nonce, err = _M.check_identity()
	if not app_key or not nonce then
	    ngx.log(ngx.DEBUG, "auth faild: ", err)
	    return ngx.exit(ngx.HTTP_UNAUTHORIZED)
	end

	if ngx.req.get_method() ~= "GET" then
	    ngx.req.read_body();
	    local raw = ngx.req.get_body_data();
	    local ok, err = _M.check_body_sign(app_key, nonce, raw)
	    if not ok then
	        ngx.log(ngx.DEBUG, "auth faild: ", err)
	        return ngx.exit(ngx.HTTP_UNAUTHORIZED)
	    end
	    ngx.ctx["body_raw"] = raw
	end
end

function _M.check_identity()
    local k, n, c, p, err = parse_username_token()
    if not k then
        return false, err
    end

    local secret_key = system.get_config()["auth"]["app"][k]
    if not secret_key then
        return nil, nil, "invalid app key"
    end

    local _digest, err = gen_pwd_digest(secret_key, n, c)
    if not _digest then
        return nil, nil, err
    end

    if _digest ~= p then
        return nil, nil, "the app-key and app-secret is not match"
    end
    return k, n
end

function _M.check_body_sign(app_key, nonce, raw_body)
    local signature, err = parse_sign_body()
    if not signature then
        return nil, err
    end

    local secret_key = system.get_config()["auth"]["app"][app_key]
    if not secret_key then
        return nil, "invalid app key"
    end

    local _signature, err = gen_body_sign(app_key .. "&" .. secret_key .. "&" .. nonce, raw_body)
    if not _signature then
        return nil, err
    end
    if _signature ~= signature then
        return nil, "the request body signature is not valid"
    end
    return true
end

-- 检查认证的领域
function _M.check_realm()
    local realm, err = parse_realm()
    if not realm then
        return nil, err
    end

    if config.get_auth_clients()[realm] then
        return true
    else
        return nil, "invalid realm."
    end
end

return _M
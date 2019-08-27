--[[
	Module L_CarNet1.lua
	
	Written by R.Boer. 
	V2.4, 27 August 2019
	
	V2.4 changes:
			- Updated for new WE Connect portal.
	V2.3 changes:
			- Doors lockData logic changed by VW. Changed to match.
	V2.2 changes:
			- Added get-vehicle-details to polling loop as some details are no longer in get-vsr.
	V2.1.1 changes:
			- Bug fix.
	V2.1 changes:
			- Some rewrites to make modules more logical.
	V2.0 changes:
			- New polling logic to match updated CarNet web site.
	V1.7 changes:
			- Option to set polling frequency when house mode is vacation.
	V1.6 changes:
			- Set timeout in https calls as GetVSR hangs openLuup sometimes.

	This plug-in emulates a browser accessing the VolksWagen Carnet portal www.volkswagen-car-net.com.
	A valid CarNet registration is required.
	
	At this moment only openLuup is supported provided it has LuaSec 0.7 installed. With LuaSec 0.5 the portal login will fail.

]]

local ltn12 	= require("ltn12")
local json 		= require("dkjson")
local https     = require("ssl.https")
local http		= require("socket.http")
local url 		= require("socket.url")

local pD = {
	Version = '2.4',
	SIDS = { 
		MODULE = 'urn:rboer-com:serviceId:CarNet1',
		ALTUI = 'urn:upnp-org:serviceId:altui1',
		HA = 'urn:micasaverde-com:serviceId:HaDevice1',
		ZW = 'urn:micasaverde-com:serviceId:ZWaveDevice1',
		ENERGY = 'urn:micasaverde-com:serviceId:EnergyMetering1'
	},
	DEV = nil,
	Description = 'VW CarNet',
	onOpenLuup = false,
	lastVsrReqStarted = 0,
	RetryDelay = 20,
	RetryMax = 6,
	PollDelay = 20,
	RetryCount = 0,
	PendingAction = ''
}

local actionStateMap = {
	['startCharge'] 	= { var = 'Charge', succeed = 1, failed =0, msg = 'charging start' },
	['stopCharge'] 		= { var = 'Charge', succeed = 0, failed = 1, msg = 'charging stop' },
	['startClimate'] 	= { var = 'Climate', succeed = 1, failed =0, msg = 'climatisation start' },
	['stopClimate'] 	= { var = 'Climate', succeed = 0, failed = 1, msg = 'climatisation stop' },
	['startWindowMelt'] = { var = 'WindowMelt', succeed = 1, failed = 0, msg = 'window heating start' },
	['stopWindowMelt'] 	= { var = 'WindowMelt', succeed = 0, failed = 1, msg = 'window heating stop' }
}

local actionTypeMap = {
	['START'] = 'startCharge',
	['STOP'] = 'stopCharge',
	['START_CLIMATISATION'] = 'startClimate',
	['STOP_CLIMATISATION'] = 'stopClimate',
	['START_WINDOW_HEATING'] = 'startWindowMelt',
	['STOP_WINDOW_HEATING'] = 'stopWindowMelt'
}

-- Define message when condition is not true
local messageMap = {
	{var='ChargeStatus', val='0', msg='Charging On'},
	{var='ClimateStatus', val='0', msg='Climatizing On'},
	{var='WindowMeltStatus',val='0',msg='Window Melt On'},
	{var='DoorsStatus',val='Closed',msg='Doors Open'},
	{var='LocksStatus',val='Locked',msg='Doors Unlocked'},
	{var='WindowsStatus',val='Closed',msg='Windows Open'},
	{var='SunroofStatus',val='Closed',msg='Sunroof Open'},
	{var='LightsStatus',val='Off',msg='Lights Open'},
	{var='PackageServiceExpireInAmonth',val='0',msg='Subscription to Expire'}
}

local myCarNet
local myModule
local log
local var


-- API getting and setting variables and attributes from Vera more efficient.
local function varAPI()
	local def_sid, def_dev = '', 0
	
	local function _init(sid,dev)
		def_sid = sid
		def_dev = dev
	end
	
	-- Get variable value
	local function _get(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		return (value or '')
	end

	-- Get variable value as number type
	local function _getnum(name, sid, device)
		local value = luup.variable_get(sid or def_sid, name, tonumber(device or def_dev))
		local num = tonumber(value,10)
		return (num or 0)
	end
	
	-- Set variable value
	local function _set(name, value, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local old = luup.variable_get(sid, name, device)
		if (tostring(value) ~= tostring(old or '')) then 
			luup.variable_set(sid, name, value, device)
		end
	end

	-- create missing variable with default value or return existing
	local function _default(name, default, sid, device)
		local sid = sid or def_sid
		local device = tonumber(device or def_dev)
		local value = luup.variable_get(sid, name, device) 
		if (not value) then
			value = default	or ''
			luup.variable_set(sid, name, value, device)	
		end
		return value
	end
	
	-- Get an attribute value, try to return as number value if applicable
	local function _getattr(name, device)
		local value = luup.attr_get(name, tonumber(device or def_dev))
		local nv = tonumber(value,10)
		return (nv or value)
	end

	-- Set an attribute
	local function _setattr(name, value, device)
		luup.attr_set(name, value, tonumber(device or def_dev))
	end
	
	return {
		Get = _get,
		Set = _set,
		GetNumber = _getnum,
		Default = _default,
		GetAttribute = _getattr,
		SetAttribute = _setattr,
		Initialize = _init
	}
end

-- API to handle basic logging and debug messaging
local function logAPI()
local def_level = 1
local def_prefix = ''
local def_debug = false
local def_file = false
local max_length = 100
local onOpenLuup = false
local taskHandle = -1

	local function _update(level)
		if level > 100 then
			def_file = true
			def_debug = true
			def_level = 10
		elseif level > 10 then
			def_debug = true
			def_file = false
			def_level = 10
		else
			def_file = false
			def_debug = false
			def_level = level
		end
	end	

	local function _init(prefix, level, onol)
		_update(level)
		def_prefix = prefix
		onOpenLuup = onol
	end	
	
	-- Build loggin string safely up to given lenght. If only one string given, then do not format because of length limitations.
	local function prot_format(ln,str,...)
		local msg = ""
		local sf = string.format
		if arg[1] then 
			_, msg = pcall(sf, str, unpack(arg))
		else 
			msg = str or "no text"
		end 
		if ln > 0 then
			return msg:sub(1,ln)
		else
			return msg
		end	
	end	
	local function _log(...) 
		if (def_level >= 10) then
			luup.log(def_prefix .. ": " .. prot_format(max_length,...), 50) 
		end	
	end	
	
	local function _info(...) 
		if (def_level >= 8) then
			luup.log(def_prefix .. "_info: " .. prot_format(max_length,...), 8) 
		end	
	end	

	local function _warning(...) 
		if (def_level >= 2) then
			luup.log(def_prefix .. "_warning: " .. prot_format(max_length,...), 2) 
		end	
	end	

	local function _error(...) 
		if (def_level >= 1) then
			luup.log(def_prefix .. "_error: " .. prot_format(max_length,...), 1) 
		end	
	end	

	local function _debug(...)
		if def_debug then
			luup.log(def_prefix .. "_debug: " .. prot_format(-1,...), 50) 
		end	
	end
	
	-- Write to file for detailed analisys
	local function _logfile(...)
		if def_file then
			local fh = io.open("/tmp/carnet.log","a")
			local msg = os.date("%d/%m/%Y %X") .. ": " .. prot_format(-1,...)
			fh:write(msg)
			fh:write("\n")
			fh:close()
		end	
	end
	
	local function _devmessage(devID, isError, timeout, ...)
		local message =  prot_format(60,...)
		local status = isError and 2 or 4
		-- Standard device message cannot be erased. Need to do a reload if message w/o timeout need to be removed. Rely on caller to trigger that.
		if onOpenLuup then
			taskHandle = luup.task(message, status, def_prefix, taskHandle)
			if timeout ~= 0 then
				luup.call_delay("logAPI_clearTask", timeout, "", false)
			else
				taskHandle = -1
			end
		else
			luup.device_message(devID, status, message, timeout, def_prefix)
		end	
	end
	
	local function logAPI_clearTask()
		luup.task("", 4, def_prefix, taskHandle)
		taskHandle = -1
	end
	_G.logAPI_clearTask = logAPI_clearTask
	
	return {
		Initialize = _init,
		Error = _error,
		Warning = _warning,
		Info = _info,
		Log = _log,
		Debug = _debug,
		Update = _update,
		LogFile = _logfile,
		DeviceMessage = _devmessage
	}
end 

-- Interfaces to system
local function SetSessionDetails(userURL,token,cookies)
	var.Set("userURL",(userURL or ''))
	var.Set("Token",(token or ''))
	var.Set("Cookies",(cookies or ''))
end
local function GetSessionDetails()
	local userURL = var.Get("userURL")
	local token = var.Get("Token")
	local cookies = var.Get("Cookies")
	return userURL,token,cookies
end


-- The API to emulate the CarNet browser client behavior
local function CarNetAPI()
	-- Map commands to details
	local commands = {
		['startCharge'] = { url ='/-/emanager/charge-battery', json = '{ "triggerAction" : true, "batteryPercent" : 100 }' },
		['stopCharge'] = { url ='/-/emanager/charge-battery', json = '{ "triggerAction" : false, "batteryPercent" : 99 }' },
		['startClimate'] = { url ='/-/emanager/trigger-climatisation', json = '{ "triggerAction" : true, "electricClima" : true }' },
		['stopClimate'] = { url ='/-/emanager/trigger-climatisation', json = '{ "triggerAction" : false, "electricClima" : true }' },
		['startWindowMelt'] = { url ='/-/emanager/trigger-windowheating', json = '{ "triggerAction" : true }' },
		['stopWindowMelt'] = {url ='/-/emanager/trigger-windowheating', json = '{ "triggerAction" : false }' },
		['getNewMessages'] = {url ='/-/msgc/get-new-messages' },
		['getEManager'] = {url ='/-/emanager/get-emanager' },
		['getLocation'] = {url ='/-/cf/get-location' },
		['getVehicleDetails'] = {url ='/-/vehicle-info/get-vehicle-details' },
		['getVsr'] = {url ='/-/vsr/get-vsr' },
		['getRequestVsr'] = {url ='/-/vsr/request-vsr' },
		['getFullyLoadedCars'] = {url ='/-/mainnavigation/get-fully-loaded-cars' },
		['getNotifications'] = {url ='/-/emanager/get-notifications' },
		['getTripStatistics'] = {url ='/-/rts/get-latest-trip-statistics' }
	}
	
	-- WE Connect portal location
	local port_host = "www.portal.volkswagen-we.com"
	-- We need to store cookies received per site
	local cookie_tab = {}
	cookie_tab[port_host] = {}

	local langCodes = {
		['NL'] = 'nl_NL',
		['GB'] = 'en_GB',
		['BE-NL'] = 'nl-BE',
		['BE-FR'] = 'fr-BE',
		['BA'] = 'bs-BA',
		['BG'] = 'bg-BG',
		['CZ'] = 'cs-CZ',
		['DK'] = 'da-DK',
		['DE'] = 'de-DE',
		['EE'] = 'et-EE',
		['GR'] = 'el-GR',
		['ES'] = 'es-ES',
		['FR'] = 'fr-FR',
		['HR'] = 'hr-HR',
		['IS'] = 'is-IS',
		['IE'] = 'en-IE',
		['IT'] = 'it-IT',
		['LV'] = 'lv-LV',
		['LT'] = 'lt-LT',
		['LU-FR'] = 'fr-LU',
		['LU-DE'] = 'de-LU',
		['HU'] = 'hu-HU',
		['MT'] = 'en-MT',
		['NO'] = 'no-NO',
		['AT'] = 'de-AT',
		['PL'] = 'pl-PL',
		['PT'] = 'pt-PT',
		['RO'] = 'ro-RO',
		['CH'] = 'de-CH',
		['SI'] = 'sl-SI',
		['SK'] = 'sk-SK',
		['FI'] = 'fi-FI',
		['SE'] = 'sv-SE',
		['UA'] = 'uk-UA',
		['US'] = 'en-US',
		['JP'] = 'ja-JP',
		['CN'] = 'zh-CN'
	}
	
	-- Internal functions
	-- Get language code for country code
	local function _getlanguacode(cc)
		return (langCodes[cc] or 'en_GB')
	end	
	
	-- Get all parameters from the URL, or just the one specified
	local function extract_url_parameters(url,key)
		local function urldecode(s)
			local sc = string.char
			s = s:gsub('+', ' '):gsub('%%(%x%x)', function(h)
				return sc(tonumber(h, 16))
				end)
		return s
		end
	
		local ans = {}
		for k,v in url:gmatch('([^&=?]-)=([^&=?]+)' ) do
			if key then
				if k == key then
					return urldecode(v)
				end
			else
				ans[ k ] = urldecode(v)
			end
		end
		if key then
			return ''
		else	
			return ans
		end	
	end

	-- Handle post header x-www-form-urlencoded encoding
	local function _postencodepart(s)
		return s and (s:gsub("%W", function (c)
			local sf = string.format
			if c ~= "." and c ~= "_" and c ~= "-" then
				return sf("%%%02X", c:byte());
			else
				return c;
			end
		end));
	end
	local function postencode(p_data)
		local ti = table.insert
		local tc = table.concat
		local result = {};
		if p_data[1] then -- Array of ordered { name, value }
			for _, field in ipairs(p_data) do
				ti(result, _postencodepart(field[1]).."=".._postencodepart(field[2]));
			end
		else -- Unordered map of name -> value
			for name, value in pairs(p_data) do
				ti(result, _postencodepart(name).."=".._postencodepart(value));
			end
		end
		return tc(result, "&");
	end
	
	-- Parse cookie-set and store cookies
	local function cookies_parse(cookie_tab, cookies)
		local sm = string.match
		local sg = string.gsub
		local sgm = string.gmatch
		local cookies = sg(cookies, "Expires=(.-); ", "")
		for cookie in sgm(cookies..',','(.-),') do
			local key,val,pth = sm(cookie..";", '(.-)=(.-); [P|p]ath=(.-);')
			key = sg(key," ","")
			if pth == "/" then pth = "" end
			cookie_tab[key..pth] = val
		end
	end

	-- Get the value of a given cookie on path
	local function cookies_get(cookie_tab,key,pth)
		return cookie_tab[(key or "XxXx")..(pth or "")] or ''
	end

	-- Build a cookie string for the given cookie keys/paths
	local function cookies_build(cookie_tab,...)
		local sm = string.match
		local keys = {...}
		local cookies = ''
		for _, key in ipairs(keys) do
			local kv, kp = sm(key,"(.-)(/.*)")
			if not kv then kv = key end
			local val = cookies_get(cookie_tab,kv,kp)
			-- Only add if we know the cookie
			if val ~= '' then
				if cookies == '' then
					cookies = kv.."="..val
				else
					cookies = cookies.."; "..kv.."="..val
				end    
			end	
		end
		return cookies
	end

	-- HTTPs Get request
	local function HttpsGet(strURL,ReqHdrs)
		local result = {}
		http.TIMEOUT = 15  -- V1.6
		local bdy,cde,hdrs,stts = https.request{
			url=strURL, 
			method='GET',
			sink=ltn12.sink.table(result),
			redirect = false,
			headers = ReqHdrs
		}
		return bdy,cde,hdrs,result
	end	

	-- HTTPs POST request
	local function HttpsPost(strURL,ReqHdrs,PostData)
		local result = {}
		local request_body = nil
log.Debug("HttpsPost 1 %s", strURL)		
		if PostData then
			local sl = string.len
			-- We pass JSONs as string as they are simple in this application
			if type(PostData) == 'string' then
				ReqHdrs["content-type"] = 'application/json;charset=UTF-8'
				request_body=PostData
			else	
				ReqHdrs["content-type"] = 'application/x-www-form-urlencoded'
				request_body=postencode(PostData)
			end
			ReqHdrs["content-length"] = sl(request_body)
log.Debug("HttpsPost 2 body: %s",request_body)		
		else	
log.Debug("HttpsPost 2, no body ")		
			ReqHdrs["content-length"] = '0'
		end 
		http.TIMEOUT = 15  -- V1.6
		local bdy,cde,hdrs,stts = https.request{
			url=strURL, 
			method='POST',
			sink=ltn12.sink.table(result),
			source = ltn12.source.string(request_body),
			headers = ReqHdrs
		}
log.Debug("HttpsPost 3 %d", cde)		
		return bdy,cde,hdrs,result
	end	

	-- API functions 
	local function _init()
		
	end
	
	-- Format error message as CarNet like response.
	local function _build_error_message(cde, acttp, title, msg)
		local cd = cde or '0'
		local ti = title or 'Error Title'
		local ap = acttp or 'UNKNOWN'
		local ms = msg or 'Error Message'
		return '{"errorCode":"'..cde..'", "actionNotification" : {"actionState":"FAILED","actionType":"'..ap..'","errorTitle":"'..ti..'", "errorMessage":"'..ms..'" }}'
	end

	-- Login to portal
	local function _portal_login(email, password, cc)
		log.Debug('Enter PortalLogin : %s', email)
		local sec_host = 'identity.vwgroup.io'
		local bdy,cde,hdrs,result
		local sf = string.format
		local sm = string.match
		local sg = string.gsub
		local ss = string.sub
		local sl = string.len
		local tc = table.concat

		-- The different URL formatters to use
		local URLS = { 
			'https://%s/portal', 
			'https://%s/portal/%s/web/guest/home', 
			'https://%s/portal/%s/web/guest/home/-/csrftokenhandling/get-login-url',
			'https://%s/signin-service/v1/%s/login/identifier',
			'https://%s/signin-service/v1/%s/login/authenticate',
			'https://%s/portal/web/guest/complete-login?p_auth=%s&p_p_id=33_WAR_cored5portlet&p_p_lifecycle=1&p_p_state=normal&p_p_mode=view&p_p_col_id=column-1&p_p_col_count=1&_33_WAR_cored5portlet_javax.portlet.action=getLoginStatus'
		}
		local user_agent = 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:57.0) Gecko/20100101 Firefox/57.0'
		local isoLC = _getlanguacode(cc)
		-- Need seperate cookie list for sec_host
		cookie_tab[sec_host] = {}
		
		-- Step 1
		log.Debug("Step 1 ===========")
		-- Request landing page and get CSFR Token and JSESSIONID cookie:
		local req_hdrs = {
			['host'] = port_host,
			['accept'] = '*/*',
			['accept-encoding'] = 'identity',
			['user-agent'] = user_agent,
			['connection'] = 'keep-alive'
		}
		local landing_page_url = sf(URLS[2], port_host, isoLC)
		bdy,cde,hdrs,result = HttpsGet(landing_page_url, req_hdrs)
		if cde ~= 200 then return '', '1', 'Incorrect response code ' .. cde .. ' expect 200' end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		if cookies_get(cookie_tab[req_hdrs['host']], "JSESSIONID") == '' then return '', '1.1', 'Did not get JSESSIONID cookie' end
		-- Get x-csrf-token from html result
		local csrf = sm(result[1],'<meta name="_csrf" content="(%w+)"/>')
		if not csrf then return '', '1.2', 'No X-CSRF token found' end
		log.Debug('_csrf from landing page : %s', csrf)

		-- Step 2
		log.Debug("Step 2 ===========")
		-- Get login page. E.g. "https://[port_host]/portal/nl_NL/web/guest/home/-/csrftokenhandling/get-login-url"
		req_hdrs = {
			['host'] = port_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'identity',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[1], port_host),
			['x-csrf-token'] = csrf,
			['cookie'] = cookies_build(cookie_tab[port_host],"JSESSIONID", "LB-ID", "GUEST_LANGUAGE_ID", "COOKIE_SUPPORT", "CARNET_LANGUAGE_ID"),
			['connection'] = 'keep-alive'
		}
		local get_login_url = sf(URLS[3], port_host, isoLC)
		bdy,cde,hdrs,result = HttpsPost(get_login_url,req_hdrs)
		if cde ~= 200 then return '', '2', 'Incorrect response code ' .. cde .. ' expect 200' end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		local responseData = json.decode(tc(result))
		local login_url = responseData.loginURL.path
		if not login_url then return '', '2.1', 'Missing redirect location in response' end
		login_url = sg(login_url, " ", "%%20")
		local client_id = extract_url_parameters(login_url, 'client_id')
		if not client_id then return '', '2.2', 'Failed to get client_id' end
		log.Debug("client_id found: %s", client_id)
	
		-- Step 3
		log.Debug("Step 3 ===========")
		-- Get login form url we are told to use, it will give us a new location.
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[1], port_host),
			['x-csrf-token'] = csrf,
			['connection'] = 'keep-alive'
		}
		-- stops here unless you install luasec 0.7 as SNI is not supported by luasec 0.5 or 0.6. Show stopper for Vera it seems.
		bdy,cde,hdrs,result = HttpsGet(login_url,req_hdrs)
		if cde ~= 302 then return '', '3', 'Incorrect response code ' .. cde .. ' expect 302'   end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		if cookies_get(cookie_tab[req_hdrs['host']], "JSESSIONID", "/oidc") == '' then return '', '3.1', 'Did not get JSESSIONID cookie' end
		local login_form_url = hdrs.location
		if not login_form_url then return '', '3.2', 'Missing redirect location in return header' end
		local login_relay_state_token = extract_url_parameters(login_form_url, 'relayState')
		if not login_relay_state_token then return '', '3.3', 'Failed to get relayState' end
		log.Debug("relayState found: %s", login_relay_state_token)
	
		-- Step 4
		log.Debug("Step 4 ===========")
		-- Get login action url, relay state. hmac token 1 and login CSRF from form contents
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'identity',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[1], port_host),
			['x-csrf-token'] = csrf,
			['cookie'] = cookies_build(cookie_tab[sec_host], "accept-language", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(login_form_url,req_hdrs)
		if cde ~= 200 then return '', '4', 'Incorrect response code ' .. cde .. ' expect 200'   end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		if cookies_get(cookie_tab[req_hdrs['host']], "SESSION", "/signin-service/v1/") == '' then return '', '4.1', 'Did not get SESSION cookie' end
		-- Get hmac and csrf tokens from form content.
		local login_form_location_response_data = tc(result)
		local hmac_token1 = sm(login_form_location_response_data,'<input type="hidden" id="hmac" name="hmac" value="(.-)"/>')
		local login_csrf = sm(login_form_location_response_data,'<input type="hidden" id="csrf" name="_csrf" value="(.-)"/>')
		if not login_csrf then return '', '4.2', 'Failed to get login CSRF'  end
		if not hmac_token1 then return '', '4.3', 'Failed to get  1st HMAC token'  end
		log.Debug("login_csrf found: %s", login_csrf)
		log.Debug("hmac_token1 found: %s", hmac_token1)

		-- Step 5
		-- Post login identifier (email)
		log.Debug("Step 5 ===========")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = login_form_url,
			['cookie'] = cookies_build(cookie_tab[sec_host], "SESSION/signin-service/v1/"),
			['connection'] = 'keep-alive'
		}
		local post_data = { 
			{'email', email},
			{'relayState', login_relay_state_token},
			{'hmac', hmac_token1},
			{'_csrf', login_csrf}
		}
		local login_action_url = sf(URLS[4], sec_host, client_id)
		bdy,cde,hdrs,result = HttpsPost(login_action_url, req_hdrs, post_data)
		if cde ~= 303 then return '', '5', 'Incorrect response code ' .. cde .. ' expect 303' end
		if not hdrs.location then return '', '5.1', 'Missing redirect location in return header' end
		if ss(hdrs.location, 1, sl('https://'..sec_host)) ~= 'https://'..sec_host then
			login_action_url = 'https://'..sec_host..hdrs.location
		else
			login_action_url = hdrs.location
		end
		-- Step 5.1
		-- Get redirect location
		log.Debug("Step 5.1")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'identity',
			['user-agent'] = user_agent,
			['referer'] = login_form_url,
			['cookie'] = cookies_build(cookie_tab[sec_host], "SESSION/signin-service/v1/", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(login_action_url,req_hdrs)
		if cde ~= 200 then return '', '5.2', 'Incorrect response code ' .. cde .. ' expect 200' end
		local login_form_location_response_data = tc(result)
		local hmac_token2 = sm(login_form_location_response_data,'<input type="hidden" id="hmac" name="hmac" value="(.-)"/>')
		if not hmac_token2 then return '', '5.3', 'Failed to get 2nd HMAC token'  end
		log.Debug("hmac_token2 found: %s", hmac_token2)

		-- Step6
		-- Post login authenticate
		log.Debug("Step 6 ===========")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[4], sec_host, client_id),
			['cookie'] = cookies_build(cookie_tab[sec_host], "SESSION/signin-service/v1/", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		local post_data = { 
			{'relayState', login_relay_state_token},
			{'hmac', hmac_token2},
			{'_csrf', login_csrf},
			{'login','true'},
			{'password', password},
			{'email', email}
		}
		login_action_url = sf(URLS[5], sec_host, client_id)
		bdy,cde,hdrs,result = HttpsPost(login_action_url, req_hdrs, post_data)
		if cde ~= 302 then return '', '6', 'Incorrect response code ' .. cde .. ' expect 302' end
		if not hdrs.location then return '', '6.1', 'Missing redirect location in return header' end
		-- Step 6.1
		log.Debug("Step 6.1")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[4], sec_host, client_id),
			['cookie'] = cookies_build(cookie_tab[sec_host], "JSESSIONID/oidc", "__VCAP_ID__/oidc", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(hdrs.location,req_hdrs)
		if cde ~= 302 then return '', '6.2', 'Incorrect response code ' .. cde .. ' expect 302' end
		if not hdrs.location then return '', '6.3', 'Missing redirect location in return header' end
		-- Step 6.2
		log.Debug("Step 6.2")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[4], sec_host, client_id),
			['cookie'] = cookies_build(cookie_tab[sec_host], "SESSION/signin-service/v1/", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(hdrs.location,req_hdrs)
		if cde ~= 302 then return '', '6.4', 'Incorrect response code ' .. cde .. ' expect 302' end
		if not hdrs.location then return '', '6.5', 'Missing redirect location in return header' end
		-- Step 6.3
		log.Debug("Step 6.3")
		req_hdrs = {
			['host'] = sec_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[4], sec_host, client_id),
			['cookie'] = cookies_build(cookie_tab[sec_host], "JSESSIONID/oidc", "__VCAP_ID__/oidc", "vcap_journey"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(hdrs.location,req_hdrs)
		if cde ~= 302 then return '', '6.7', 'Incorrect response code ' .. cde .. ' expect 302' end
		local login_complete_url = hdrs.location or ''
		if login_complete_url == '' then return '', '6.8', 'Missing redirect location in return header' end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		-- Step 6.4
		log.Debug("Step 6.4")
		req_hdrs = {
			['host'] = port_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = sf(URLS[4], sec_host, client_id),
			['cookie'] = cookies_build(cookie_tab[port_host],"JSESSIONID", "LB-ID", "GUEST_LANGUAGE_ID", "COOKIE_SUPPORT", "CARNET_LANGUAGE_ID"),
			['connection'] = 'keep-alive'
		}
		local query = extract_url_parameters(login_complete_url)
		bdy,cde,hdrs,result = HttpsGet(login_complete_url,req_hdrs)
		if cde ~= 200 then return '', '6.7', 'Incorrect response code ' .. cde .. ' expect 200' end
		local portlet_code = query.code
		local state = query.state
		if not portlet_code then return '', '6.8', 'Missing portlet_code' end
		if not state then return '', '6.8', 'Missing state' end

		-- Step 7 
		-- Complete last login step by posting portlet
		log.Debug("Step 7 ===========")
		req_hdrs = {
			['host'] = port_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'gzip, deflate, br',
			['user-agent'] = user_agent,
			['referer'] = login_complete_url,
			['cookie'] = cookies_build(cookie_tab[port_host],"JSESSIONID", "LB-ID", "GUEST_LANGUAGE_ID", "COOKIE_SUPPORT", "CARNET_LANGUAGE_ID"),
			['connection'] = 'keep-alive'
		}
		post_data = { 
			{'_33_WAR_cored5portlet_code', portlet_code }
		}
		local final_login_url = sf(URLS[6], port_host, state)
		bdy,cde,hdrs,result = HttpsPost(final_login_url,req_hdrs, post_data)
		if cde ~= 302 then return '', '7', 'Incorrect response code ' .. cde .. ' expect 302' end
		if (hdrs and hdrs['set-cookie']) then 
			cookies_parse(cookie_tab[req_hdrs['host']], hdrs['set-cookie'])
		end
		if cookies_get(cookie_tab[req_hdrs['host']], "JSESSIONID") == '' then return '', '7.1', 'Missing JSESSIONID in return set-cookie' end
		local base_json_url = hdrs.location
		if not base_json_url then return '', '7.2', 'Missing redirect location in return header' end

		-- Step 8
		-- Go to home page or get command on reconnect
		log.Debug("Step 8 ===========")
		req_hdrs = {
			['host'] = port_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8',
			['accept-encoding'] = 'identity',
			['user-agent'] = user_agent,
			['referer'] = login_complete_url,
			['cookie'] = cookies_build(cookie_tab[port_host],"JSESSIONID", "LB-ID", "GUEST_LANGUAGE_ID", "COOKIE_SUPPORT", "CARNET_LANGUAGE_ID"),
			['connection'] = 'keep-alive'
		}
		bdy,cde,hdrs,result = HttpsGet(base_json_url,req_hdrs)
		if cde ~= 200 then return '', '8', 'Incorrect response code ' .. cde .. ' expect 200' end
	
		--We have a new CSRF
		csrf = sm(result[1],'<meta name="_csrf" content="(%w+)"/>')
		if not csrf then return '', '8.1', 'No CSRF token found' end
		-- done!!!! we are in at last
		log.Debug('Login done. X-CSRF Token : %s', csrf)	
		return base_json_url, csrf, cookies_build(cookie_tab[port_host],"JSESSIONID", "LB-ID", "GUEST_LANGUAGE_ID", "COOKIE_SUPPORT", "CARNET_LANGUAGE_ID")
	end
	
	-- Get string of supported languages
	local function _getlanguages()
		local ll
		for k,v in pairs(langCodes) do
			ll = (ll and ll..","..k) or k
		end
		return ll
	end
	
	-- Send a command to the portal, calling routines must assure initial login has happened.
	local function _sendcommand(command, token, cookies, base_url)
		log.Debug('Enter SendCommand :'.. command)
		local cm_url = commands[command].url
		local cm_data = commands[command].json
		if cm_url then 
			local tc = table.concat
			local isoLC = _getlanguacode(cc)
			local req_hdrs = { 
				['accept'] = 'application/json, text/plain, */*',
				['content-type'] = 'application/json;charset=UTF-8',
				['user-agent'] = user_agent,
				['x-csrf-token'] = token,
				['referer'] = base_url,
				['cookie'] = cookies
			}
log.Debug('SendCommand Cookie 2 : %s',cookies)
			
			local bdy,cde,hdrs,result = HttpsPost(base_url..cm_url,req_hdrs,cm_data)
log.Debug('SendCommand res : %d',cde)
			-- We have a redirect because session expired, so tell caller to login again
			if cde == 302 then
				return cde
			elseif cde == 200 then
				return cde, tc(result)
			else
				log.Error('Incorrect responce code %s', cde)
				return cde, _build_error_message(cde, "SEND_COMMAND","Could not send command","Invalid response code "..cde.." received. Expected 200 or 302.")
			end
		else
			log.Log('Unknown command : '..command)
		end
	end

	return {
		Initialize = _init,
		PortalLogin = _portal_login,
		SendCommand = _sendcommand,
		GetLanguages = _getlanguages,
		BuildErrorMessage = _build_error_message
	}
end

-- Interface of the module
function CarNetModule()

	-- API functions 
	-- Initialize module
	local function _init()
	
		-- Create variables we will need from get-go
		var.Set("Version", pD.Version)
		var.Default("Email")
		var.Default("Password")
		var.Default("LogLevel", pD.LogLevel)
		var.Default("userURL")
		var.Default("Token")
		var.Default("SessionID")
		var.Default("Cookies")
		var.Default("Language", "GB")
		var.Default("PollSettings", '5,60,120,15,1440') -- Active, Home Idle, Away Idle, FastPoll, Vacation location
		var.Default("LocationHome","0")
		var.Default("CarName")
		var.Default("RequestStatus")
		var.Default("LastCarMessageTimestamp")
		var.Default("ServiceInspectionData")
		var.Default("PackageService")
		var.Default("PackageServiceActDate")
		var.Default("PackageServiceExpDate")
		var.Default("PackageServiceExpired","0")
		var.Default("PackageServiceExpireInAmonth","0")
		var.Default("LastFLCPoll", 0)
		var.Default("ChargeStatus", "0")
		var.Default("ClimateStatus", "0")
		var.Default("WindowMeltStatus", "0")
		var.Default("ChargeMessage")
		var.Default("ClimateMessage")
		var.Default("WindowMeltMessage")
		var.Default("DoorsStatus","Closed")
		var.Default("LocksStatus","Locked")
		var.Default("WindowsStatus","Closed")
		var.Default("SunroofStatus","Closed")
		var.Default("LightsStatus","Off")
		var.Default("HoodStatus","Closed")
		var.Default("Mileage")
		var.Default("ActionRetries", "0")
		var.Default("LocationHome", "0")
		var.Default("FastPollLocations")
		var.Default("AtLocationRadius", 0.5)
		var.Default("PowerSupplyConnected", "0")
		var.Default("NoPollWindow","23:30-7:30")
		var.Default("IconSet",0)
		return true
	end
	
	-- Set best status message
	local function _set_status_message(proposed)
		local msg = ''
		if proposed then
			msg = proposed
		else	
			-- Look for messages based on key status items
			for k, msg_t in pairs(messageMap) do
				local val = var.Get(msg_t.var)
				if val ~= msg_t.val then
					msg = msg_t.msg
					break
				end    
			end
		end
		var.Set('DisplayLine2', msg, pD.SIDS.ALTUI)
	end

	-- Erase userURL and related values. This will fore a new login
	local function _reset()
		SetSessionDetails('','','')
		var.Default("LastFLCPoll", 0)
	end
	
	local function _login()
		local email = var.Get('Email')
		local password = var.Get('Password')
		local cc = var.Get('Language')
		if email ~= '' and password ~= '' and cc ~= '' then
			local userURL,token,cookies = myCarNet.PortalLogin(email, password, cc)
			if userURL ~= '' then
				SetSessionDetails(userURL, token, cookies)
				var.Set('LastLogin', os.time())
				return 200, userURL, token, cookies
			else
				log.Error('Unable to login. errorCode : %s, errorMessage : %s', token, cookies)
				return 404, "PORTAL_LOGIN","Login to CarNet Portal failed "..token..cookies
			end
		else
			log.Log('Configration not complete',5)
			return 404, 'PLUGIN_CONFIG','Plug-in setup not complete','Missing email, password and/or language, please complete setup.'
		end
	end
	
	local function _command(command)
		local userURL, token, cookies = GetSessionDetails()
		local cde
		if userURL == '' or token == '' or cookies == '' then
			-- We need to login first.
			log.Debug('No session yet, need to login')
			cde, userURL, token, cookies = _login()
			if cde ~= 200 then
				return cde, myCarNet.BuildErrorMessage(cde, userURL, token, cookies)
			end	
		end	
		log.Debug('Sending command : %s', command)
		local cde, res = myCarNet.SendCommand(command, token, cookies, userURL)
		if cde == 200 then
			log.Log('Command result : Code ; %s, Response ; %s',cde, string.sub(res,1,30))
			log.Debug(res)	
			return cde, res
		elseif cde == 302 then
			-- Session expired. We need to login again
			log.Debug('Session exipred, need to login')
			cde, userURL, token, cookies = _login()
			if cde ~= 200 then
				return cde, myCarNet.BuildErrorMessage(cde, userURL, token, cookies)
			else	
				cde, res = myCarNet.SendCommand(command, token, cookies, userURL)
				log.Log('Command result : Code ; %s, Response ; %s', cde, string.sub(res,1,30))
				log.Debug(res)	
				return cde, res
			end	
		else
			return cde, res
		end
	end
	
	-- Calculate distance between to lat/long coordinates
	local function _distance(lat1, lon1, lat2, lon2) 
		local p = 0.017453292519943295    -- Math.PI / 180
		local c = math.cos
		local a = 0.5 - c((lat2 - lat1) * p)/2 + c(lat1 * p) * c(lat2 * p) * (1 - c((lon2 - lon1) * p))/2
		return 12742 * math.asin(math.sqrt(a)) -- 2 * R; R = 6371 km
	end

	-- We have an updated VSR car status
	local function _update_car_status()
		local n_doors = 2
		local status = false
		local deb_res = ""
		
		local function buildStatusText(item, drs, lckd)
			local tc = table.concat
			local txt_t = {}
			if item.left_front ~= lckd then txt_t[#txt_t+1] = 'Left front' end
			if item.right_front ~= lckd then txt_t[#txt_t+1] = 'Right front' end
			if drs == 4 then
				if item.left_back ~= lckd then txt_t[#txt_t+1] = 'Left back' end
				if item.right_back ~= lckd then txt_t[#txt_t+1] = 'Right back' end
			end
			if item.trunk and (item.trunk ~= lckd) then txt_t[#txt_t+1] = 'Trunk' end
			if #txt_t == 0 then
				return nil
			elseif #txt_t == 1 then
				return tc(txt_t, ', ')..' is '
			elseif #txt_t < drs then
				return tc(txt_t, ', ')..' are '
			else	
				return 'All are '
			end
		end
		
		local cde, res = _command('getVsr')
		if cde == 200 then
			log.Debug('getVsr result : %s', res)
			local rjs = json.decode(res) 
			if rjs.errorCode == '0' then 
				if rjs.vehicleStatusData then
					local vsd = rjs.vehicleStatusData
					var.Set("RequestStatus",(vsd.requestStatus or "no report"))
					-- VSR has desired details, request an update and then poll until we have successful request response
					if vsd.carRenderData then
						local crd = vsd.carRenderData
						-- parking lights status 2 should be off, else on
						if crd.parkingLights then
							if crd.parkingLights ~= 2 then
								var.Set('LightsStatus','On')
							else
								var.Set('LightsStatus','Off')
							end
						end	
						-- Hood status 3 should be closed, else open
						if crd.hood then
							if crd.hood ~= 3 then
								var.Set('HoodStatus','Open')
							else
								var.Set('HoodStatus','Closed')
							end
						end	
						-- See number of doors
						if crd.doors and crd.doors.number_of_doors == 4 then n_doors = 4 end
						-- Door/trunk status 3 should be closed, else open
						if crd.doors then
							local txt = buildStatusText(crd.doors, n_doors, 3)
							if txt then
								var.Set('DoorsStatus', txt .. 'open')
								var.Set('IconSet',3)
							else	
								var.Set('DoorsStatus', 'Closed')
							end	
						end	
						-- Window status 3 should be closed, 2 (partially) open
						if crd.windows then
							local txt = buildStatusText(crd.windows, n_doors, 3)
							if txt then
								var.Set('WindowsStatus', txt .. 'open')
							else	
								var.Set('WindowsStatus', 'Closed')
							end	
						end	
						-- Sunroof status 3 should be closed, else open
						if crd.sunroof then
							if crd.sunroof ~= 3 then
								var.Set('SunroofStatus','Open')
							else
								var.Set('SunroofStatus','Closed')
							end
						end	
					end
					-- Locks status 3 should be locked, 2 unlocked
					if vsd.lockData then
						local txt =	buildStatusText(vsd.lockData, n_doors, 2)
						if txt then
							var.Set('LocksStatus', txt..'unlocked')
							var.Set('IconSet',3)
						else	
							var.Set('LocksStatus','Locked')
						end
					end	
					-- Get mileage and refresh time details
					if vsd.headerData then
						if vsd.headerData.mileage then var.Set('Mileage',vsd.headerData.mileage) end
						if vsd.headerData.lastRefreshTime then 
							var.Set('LastVsrRefreshTime',vsd.headerData.lastRefreshTime[1]..', '..vsd.headerData.lastRefreshTime[2]) 
						end
					end
					if  vsd.requestStatus then var.Set("RequestStatus",vsd.requestStatus) end
					-- Get Battery details if available, get from e-manager
					--if vsd.batteryLevel then var.Set("BatteryLevel", vsd.batteryLevel , pD.SIDS.HA) end
					--if vsd.batteryRange then var.Set("BatteryRange", vsd.batteryRange) end
					status = true
				else
					deb_res = 'getVsr failed missing Vehicle Status Data : '.. res
				end
			else
				deb_res = 'getVsr returned an error : '..res
			end
			rjs = nil
		else
			deb_res = 'getVsr HTTP error : '.. cde
		end
		return status, deb_res
	end

	-- We have an updated car location
	local function _update_car_location()
		local status = false
		local deb_res = ""
		local cde, res = _command('getLocation')
		if cde == 200 then
			log.Debug('getLocation result : %s', res)
			local rjs = json.decode(res)
			if rjs.errorCode == "0" then
				if rjs.position then
					local lat = (rjs.position.lat or 0)
					local lng = (rjs.position.lng or 0)
					var.Set('Latitude', lat)
					var.Set('Longitude', lng)
					-- Compare to home location and set/clear at home flag when within 500 m
					lat = tonumber(lat) or luup.latitude
					lng = tonumber(lng) or luup.longitude
					local radius = var.GetNumber('AtLocationRadius')
					if _distance(lat,lng, luup.latitude, luup.longitude) < radius then
						var.Set('LocationHome', 1)
					else
						var.Set('LocationHome', 0)
					end
					status = true
				else
					deb_res = 'getLocation failed missing position data : '..res
				end
			else
				deb_res = 'getLocation returned an error : '..res
			end
			rjs = nil
		else
			deb_res = 'getLocation HTTP error : '.. cde
		end
		return status, deb_res
	end
	
	-- We have updated vehicle details
	local function _update_vehicle_details()
		local status = false
		local deb_res = ""
		local cde, res = _command('getVehicleDetails')
		if cde == 200 then
			log.Debug('getVehicleDetails result : %s', res)
			local rjs = json.decode(res)
			if rjs.errorCode == "0" then
				if rjs.vehicleDetails then
					local ts = rjs.vehicleDetails.lastConnectionTimeStamp 
					if ts then
						local tsd = ts[1]
						local tst = ts[2]
						if tsd and tst then
							local tso = os.time { year=tonumber(tsd:sub(7,-1)), month=tonumber(tsd:sub(4,5)), day=tonumber(tsd:sub(1,2)), hour=tonumber(tst:sub(1,2)), min=tonumber(tst:sub(4,-1)) }
							var.Set('LastCarMessageTimestamp', (tso or 0))
						end
					end	
					var.Set('ServiceInspectionData', (rjs.vehicleDetails.serviceInspectionData or ""))
					var.Set('Mileage', (rjs.vehicleDetails.distanceCovered or "")) -- V2.2
					status = true
				else		
				deb_res = 'getVehicleDetails failed missing vehicle details : '..res
				end
			else
				deb_res = 'getVehicleDetails returned an error : '..res
			end
			rjs = nil
		else
			deb_res = 'getVehicleDetails HTTP error : '.. cde
		end
		return status, deb_res
	end

	-- We have updated e-manager data, return any remaining charge or climate time.
	local function _update_car_emanager()
		local status = false
		local deb_res = ""
		local rem_time = 0
		local cde, res = _command('getEManager')
		if cde == 200 then
			log.Debug('getEManager result : %s', res)
			local rjs = json.decode(res)
			if rjs.errorCode == "0" then
				if rjs.EManager then
					local rbcs = rjs.EManager.rbc.status
					local icon = 0
					-- Get Battery details if available
					local bp, er, ct = '','', ''
					if rbcs.batteryPercentage then 
						bp = rbcs.batteryPercentage 
						var.Set("BatteryLevel", bp , pD.SIDS.HA)
					end
					if rbcs.electricRange then 
						er = rbcs.electricRange 
						var.Set("ElectricRange", er)
					end
					-- Get charge status
					if rbcs.chargingState then var.Set("ChargeStatus", ((rbcs.chargingState == 'CHARGING' and '1') or '0')) end
					if rbcs.chargingRemaningHour and rbcs.chargingRemaningMinute then 
						rem_time = tonumber(rbcs.chargingRemaningHour) + tonumber(rbcs.chargingRemaningMinute)
						ct = rbcs.chargingRemaningHour ..':'.. rbcs.chargingRemaningMinute
						var.Set("RemainingChargeTime", ct) 
					end
					if var.GetNumber('EManager') == 1 then
						if rbcs.chargingState == 'CHARGING' then
							var.Set('ChargeMessage', 'Battery '..bp..'%, range '..er..'km, time remaning '..ct)
							var.Set('DisplayLine2', 'Charging; range '..er..'km, time remaning '..ct, pD.SIDS.ALTUI)
							icon = 1
						else	
							var.Set('ChargeMessage', 'Battery '..bp..'%, range '..er..'km')
						end
					else	
						var.Set('ChargeMessage', 'Not supported')
					end
					if rbcs.pluginState then var.Set("PowerPlugState", ((rbcs.pluginState == 'CONNECTED' and '1') or '0')) end
					if rbcs.lockState then var.Set("PowerPlugLockState", ((rbcs.lockState == 'LOCKED' and '1') or '0')) end
					if rbcs.extPowerSupplyState then var.Set("PowerSupplyConnected", ((rbcs.extPowerSupplyState == 'AVAILABLE' and '1') or '0')) end
					-- Get climatisation status
					local rpcs, tt, tr = rjs.EManager.rpc.settings, '', ''
					if rpcs.targetTemperature then 
						tt = rpcs.targetTemperature
						var.Set("ClimateTargetTemp", tt)
					end
					rpcs = rjs.EManager.rpc.status
					local wh = '0'
					if rpcs.climatisationWithoutHVPower then var.Set("ClimatesationWithoutHVPower", ((rpcs.climatisationWithoutHVPower and '1') or '0')) end
					if rpcs.climatisationState then 
						wh = ((rpcs.climatisationState == 'OFF' and '0') or '1')
						var.Set("ClimateStatus", wh) 
					end
					if rpcs.climatisationRemaningTime then 
						tr = rpcs.climatisationRemaningTime
						if rem_time == 0 then rem_time = tonumber(tr) end
						var.Set("ClimateRemainingTime", tr) 
					end
					if wh == '1' then
						var.Set('ClimateMessage', 'Target '..tt..'C, time remaning '..tr)
						if icon == 0 then icon = 2 end
					else	
						var.Set('ClimateMessage', '')
					end
					wh = '0'
					if rpcs.windowHeatingAvailable then 
						if rpcs.windowHeatingStateFront then 
							wh = (((rpcs.windowHeatingStateFront == 'ON' or rpcs.windowHeatingStateRear == 'ON') and '1') or '0')
							var.Set("WindowMeltStatus", wh)
						end	
					end	
					if wh == '0' then var.Set('WindowMeltMessage', '') end
					var.Set('IconSet',icon)
				else	
					deb_res = 'getEManager failed reading data, no EManager data : '..res
				end
				status = true
			else
				deb_res = 'getEManager returned an error : '..res
			end
			rjs = nil
		else
			deb_res = 'getEManager HTTP error : '.. cde
		end
		return status, deb_res
	end

	-- We have updated car details data
	local function _update_car_details()
		local status = false
		local deb_res = ""
		local cde, res = _command('getFullyLoadedCars')
		if cde == 200 then
			log.Debug('getFullyLoadedCars result : %s', res)
			local rjs = json.decode(res)
			if rjs.errorCode == "0" then
				if rjs.fullyLoadedVehiclesResponse then
					local data 
					-- See what entry holds the data. Not sure why my car is in vehiclesNotFullyLoaded and I do not know if completeVehicles will have the same data
					-- You should also get more details from this data when you have more then one car on the account. Not supporting this for now. Single car only.
					if #rjs.fullyLoadedVehiclesResponse.completeVehicles == 1 then 
						data = rjs.fullyLoadedVehiclesResponse.completeVehicles[1] 
					elseif #rjs.fullyLoadedVehiclesResponse.vehiclesNotFullyLoaded == 1 then 
						data = rjs.fullyLoadedVehiclesResponse.vehiclesNotFullyLoaded[1] 
					end
					if data then
						var.Set('CarName', data.name)
						var.Set('DisplayLine1',"Car : "..data.name, pD.SIDS.ALTUI)
						-- Check if we have a (Hybrid) electric car
						var.Set('EManager', (((data.engineTypeHybridOCU1 or data.engineTypeHybridOCU1 or data.engineTypeElectric) and '1') or '0'))
						-- Get package details
						if #data.packageServices == 1 then
							local pkg = data.packageServices[1]
							var.Set("PackageService", pkg.packageServiceName)
							var.Set("PackageServiceActDate", pkg.activationDate)
							var.Set("PackageServiceExpDate", pkg.expirationDate)
							var.Set("PackageServiceExpired", ((pkg.expired and '1') or '0'))
							expm = (pkg.expireInAMonth and '1') or '0'
							var.Set("PackageServiceExpireInAmonth", expm)
							if (expm == '1') then var.Set('DisplayLine2', 'Your CarNet subscription will expire '.. pkg.expirationDate, pD.SIDS.ALTUI) end
						end
						status = true
					else
						deb_res = 'getFullyLoadedCars failed reading Vehicle data : '..res
					end
				else
					deb_res = 'getFullyLoadedCars failed reading data, no Loaded Vehicles : '..res
				end
			else
				deb_res = 'getFullyLoadedCars returned an error : '..res
			end
			rjs = nil
		else
			deb_res = 'getFullyLoadedCars HTTP error : '.. cde
		end
		return status, deb_res
	end
	
	-- Times are for Active, Home Idle, Away Idle, FastPoll location
	-- Unless in No Poll time window, then do not start to end of window again.
	local function _calculate_next_poll()
		local next_poll = 0
		local poll_end, poll_start = 0,0
		local noptw = var.Get("NoPollWindow")
		if noptw ~= '' then
			local sm = string.match
			local st, et = sm(noptw,"(.-)\-(.+)")
			local hS, mS = sm(st,"(%d+):(%d+)")
			local mStart = (hS * 60) + mS
			local hE, mE = sm(et,"(%d+):(%d+)")
			local mEnd = (hE * 60) + mE
			local tNow = os.date("*t")
			local mNow = (tNow.hour * 60) + tNow.min
			tNow.hour = hS
			tNow.min = mS
			tNow.sec=0
			poll_end = os.difftime(os.time(tNow),os.time())
			tNow.hour = hE
			tNow.min = mE + 1
			local bMatch = false
			if mEnd >= mStart then
				bMatch = ((mNow >= mStart) and (mNow <= mEnd))
			else
				bMatch = ((mNow >= mStart) or (mNow <= mEnd))
				if (mNow ~= 0) and (mNow >= mStart) then  tNow.day =  tNow.day + 1 end
			end
			poll_start = os.difftime(os.time(tNow),os.time())
			if bMatch then
				-- In window, next start is end time plus one minute.
				next_poll = poll_start
			end
		end	
		if next_poll == 0 then	
			local pol = var.Get("PollSettings")
			local pol_t = {}
			string.gsub(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
			if #pol_t == 4 then 
				-- See if car is in atHome range or not
				if var.GetNumber('LocationHome') == 1 then
					next_poll = pol_t[2]
				else	
					next_poll = pol_t[3]
					-- See if we are at a fast poll location
					local fpl = var.Get('FastPollLocations')
					local lat = var.GetNumber('Latitude')
					local lng = var.GetNumber('Longitude')
					local radius = var.GetNumber('AtLocationRadius')
					if fpl ~= '' and lat ~= 0 and lng ~= 0 and radius ~= 0 then
						local locs_t = {}
						string.gsub(fpl..";","(.-);", function(c) locs_t[#locs_t+1] = c end)
						for i = 1, #locs_t do
							local lc_lat, lc_lng = string.match(locs_t[i],"(.-),(.+)")
							if _distance(tonumber(lc_lat), tonumber(lc_lng), lat, lng) < radius then
								next_poll = pol_t[4]
								break
							end
						end
					end
				end
				next_poll = next_poll * 60  -- Minutes to seconds
			elseif #pol_t == 5 then -- V1.7 and later with house mode Vacation
				-- See if House Mode is Vacation, use that poll time.
				local house_mode = var.GetAttribute("Mode",0)
				if house_mode == 4 then
					next_poll = pol_t[5]
				-- Nope, see if the car is at home location.	
				elseif var.GetNumber('LocationHome') == 1 then
					next_poll = pol_t[2]
				-- Nope, check fast poll location(s)	
				else	
					next_poll = pol_t[3]
					-- See if we are at a fast poll location
					local fpl = var.Get('FastPollLocations')
					local lat = var.GetNumber('Latitude')
					local lng = var.GetNumber('Longitude')
					local radius = var.GetNumber('AtLocationRadius')
					if fpl ~= '' and lat ~= 0 and lng ~= 0 and radius ~= 0 then
						local locs_t = {}
						string.gsub(fpl..";","(.-);", function(c) locs_t[#locs_t+1] = c end)
						for i = 1, #locs_t do
							local lc_lat, lc_lng = string.match(locs_t[i],"(.-),(.+)")
							if _distance(tonumber(lc_lat), tonumber(lc_lng), lat, lng) < radius then
								next_poll = pol_t[4]
								break
							end
						end
					end
				end
				next_poll = next_poll * 60  -- Minutes to seconds
			end
		end
		-- See if the schedule pushed us into no poll window. Then skip until end of window.
		if (poll_start ~= 0 and poll_end ~= 0 and next_poll > poll_end) then next_poll = poll_start end
		if (next_poll < 0) then next_poll = next_poll + 86400 end
		if (next_poll == 0) then next_poll = 3600 end
		log.Debug("Next poll time in %d seconds.", next_poll)
		return next_poll
	end
			
	-- Trigger an update of the car status by sending RequestVsr now. Polling will pickup on update.
	local function _poll()
		log.Debug("Poll, enter")
--		_command('getRequestVsr')
		CarNet_UpdateStatus('loop', true)
	end
	
	local function _start_action(request)
		CarNet_StartAction(request)
	end	

	return {
		Reset = _reset,
		Login = _login,
		Poll = _poll,
		Command = _command,
		StartAction = _start_action,
		UpdateCarDetails = _update_car_details,
		UpdateCarStatus = _update_car_status,
		UpdateCarLocation = _update_car_location,
		UpdateCarEManager = _update_car_emanager,
		UpdateVehicleDetails = _update_vehicle_details,
		CalculateNextPoll = _calculate_next_poll,
		SetStatusMessage = _set_status_message,
		Initialize = _init
	}
end

-- Global functions used by call backs
function CarNet_VariableChanged(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	local strNewVal = (lul_value_new or "")
	local strOldVal = (lul_value_old or "")
	local strVariable = (lul_variable or "")
	local lDevID = tonumber(lul_device or "0")
	log.Log("CarNet_VariableChanged Device " .. lDevID .. " " .. strVariable .. " changed from " .. strOldVal .. " to " .. strNewVal .. ".")

	if (strVariable == 'Email') or (strVariable == 'Password') or (strVariable == 'Language') then
		log.Debug("resetting CarNet...")
		myModule.Reset()
		log.Debug("resetting CarNet done.")
	elseif (strVariable == 'LogLevel') then	
		-- Set log level and debug flag if needed
		local lev = tonumber(strNewVal, 10) or 3
		log.Update(lev)
	end
end

-- Global routine for polling car status. Use status from CarNet web service. Car will send updates as needed.
function CarNet_UpdateStatus()
	local deb_res = ''

	-- Schedule next poll
	luup.call_delay("CarNet_UpdateStatus", myModule.CalculateNextPoll())

	log.Debug("CarNet_UpdateStatus, enter")
	-- After 24 hrs we do a getFullyLoadedCars command again
	local lfp = os.time() - var.GetNumber('LastFLCPoll')
	if lfp >  86400 then
		myModule.SetStatusMessage('Refreshing FLC...')
		-- Get high level car end CatNet subscription details, run this once a day
		local stat, deb_res = myModule.UpdateCarDetails()
		if stat then
			log.Debug('getFullyLoadedCars succeeded')
			var.Set('LastFLCPoll', os.time())
		else	
			log.Debug('getFullyLoadedCars error : %s', deb_res)
		end
	end	
	if deb_res == "" then
		myModule.SetStatusMessage('Refreshing Car status...')
		var.Set('StatusText','Update Car Status in progress....')
		local stat, deb_res = myModule.UpdateCarStatus()
		if stat then
			log.Debug('RequestStatus succeeded')
		else	
			log.Debug('RequestStatus error : %s', deb_res)
		end
	end
					
	-- Next get car location long-lat.
	if deb_res == "" then
		local stat, deb_res = myModule.UpdateCarLocation()
		if stat then
			log.Debug('UpdateCarLocation succeeded')
		else	
			log.Debug('UpdateCarLocation error : %s', deb_res)
		end
	end

	-- Next get car details.
	if deb_res == "" then
		local stat, deb_res = myModule.UpdateVehicleDetails()
		if stat then
			log.Debug('UpdateVehicleDetails succeeded')
		else	
			log.Debug('UpdateVehicleDetails error : %s', deb_res)
		end
	end

	-- If we have eManager, get its status
	if deb_res == "" then
		if var.Get('EManager') == '1' then
			local stat, deb_res = myModule.UpdateCarEManager()
			if stat then
				log.Debug('UpdateCarEManager succeeded')
			else	
				log.Debug('UpdateCarEManager error : %s', deb_res)
			end
		end
	end
	myModule.SetStatusMessage()
	if deb_res ~= '' then
		local pc = var.GetNumber("PollNoReply", pD.SIDS.ZW) + 1
		var.Set("PollNoReply", pc, pD.SIDS.ZW)
		var.Set('StatusText',deb_res:sub(1,80))
		log.Debug(deb_res)
		log.Info(deb_res)
		myModule.SetStatusMessage()
	else
		var.Set('StatusText','Update Car Status complete.')
		local pc = var.GetNumber("PollOk", pD.SIDS.ZW) + 1
		var.Set("PollOk", pc, pD.SIDS.ZW)
	end
	log.Debug("CarNet_UpdateStatus, leave")
end

-- Global routine for polling action status after it got successfully started
-- The Notification seems to have the option of multiple requests being in queued status, so we must poll until all are handled.
function CarNet_StartAction(request)
	log.Debug("CarNet_StartAction, enter for " .. request)
	-- Handle one notification. If status is still Queued, schedule next getNotification
	local function processNotification(nt, nnt, np)
		if nt then
			if nt.actionState == 'SUCCEEDED' or nt.actionState == 'SUCCEEDED_DELAYED' then
				local ts = actionTypeMap[nt.actionType]
				if ts then
					local as = actionStateMap[ts]
					if as then
						var.Set(as.var..'Status', as.succeed)
						var.Set(as.var..'Message', 'Succeeded.')
						var.Set('StatusText','Start Action, '..as.msg..' succeeded.')
						myModule.SetStatusMessage()
						-- Request eManager status if required
						CarNet_PollEManager()
					else
						log.Debug('Request '..ts..' not defined in actionStateMap.')
					end
				else
					log.Debug('actionType '..nt.actionType..' not defined in actionTypeMap.')
				end
				pD.PendingAction = ''
				pD.RetryCount = 0
			elseif nt.actionState == 'FAILED' or nt.actionState == 'FAILED_DELAYED' then
				local ts = actionTypeMap[nt.actionType]
				local retry = nil
				if ts then
					local as = actionStateMap[ts]
					if as then
						myModule.SetStatusMessage('Last action failed')
						var.Set(as.var..'Status', as.failed)
						var.Set(as.var..'Message', 'Failed: '..nt.errorTitle)
						var.Set('StatusText','Start Action, '..as.msg..' failed.')
					else
						log.Debug('Request '..ts..' not defined in actionStateMap.')
					end
					-- See if we should retry the action
					retry = var.GetNumber("ActionRetries")
					if pD.RetryCount < retry then
						luup.call_delay("CarNet_StartAction", pD.RetryDelay, pD.PendingAction)
						pD.RetryCount =  pD.RetryCount + 1
						myModule.SetStatusMessage('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
						log.Debug('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
					else
						retry = nil
					end
				else
					log.Debug('actionType '..nt.actionType..' not defined in actionTypeMap.')
				end
				if retry == nil then 
					pD.PendingAction = '' 
					pD.RetryCount = 0
				end
			else	
				-- Action(s) have not yet completed, schedule next poll. Do more frequent if we have more actions pending.
				local pt = (((nnt == 1) and pD.PollDelay) or math.floor(pD.PollDelay/2))
				luup.call_delay("CarNet_StartAction", pt, 'poll'..np)
				log.Debug('CarNet_StartAction - starting poll...')
			end
			return true
		else
			log.Debug('CarNet_StartAction - Missing notification object.')
			return false
		end
	end
	
	-- See if request is one of the commands
	local as = actionStateMap[request]
	if as then
		-- We limit to starting/stopping one action at the time to keep things simpler
		if pD.PendingAction == '' or (pD.RetryCount > 0 and pD.PendingAction == request)then
			myModule.SetStatusMessage('Starting Action...')
			pD.PendingAction = request
			var.Set('StatusText','Start Action, sending command : '..request)
			var.Set(as.var..'Message', "Pending...")
			var.Set(as.var..'Status', as.succeed)
			local cde, res = myModule.Command(request)
			local deb_stat = ''
			if cde == 200 then
				log.Debug(request..' result : '..res)
				local rjs = json.decode(res) 
				if rjs.errorCode == '0' then 
					if rjs.actionNotification then 
						processNotification(rjs.actionNotification,1,0)
					elseif rjs.actionNotificationList then 
						for i = 1, #rjs.actionNotificationList do
							processNotification(rjs.actionNotificationList[i],#rjs.actionNotificationList,0)
						end	
					end	
				else
					deb_stat = 'Failed'
				end	
			else
				deb_stat = 'Failed'
			end	
			if deb_stat ~= '' then	
				-- See if we should retry the action
				local retry = var.GetNumber("ActionRetries")
				if pD.RetryCount < retry then
					luup.call_delay("CarNet_StartAction", pD.RetryDelay, pD.PendingAction)
					pD.RetryCount =  pD.RetryCount + 1
					myModule.SetStatusMessage('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
					log.Debug('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
				else	
					myModule.SetStatusMessage('Failed')
					log.Debug('Retries #'..pD.RetryCount..' of failed '..pD.PendingAction.." all failed.")
					pD.PendingAction = ''
					pD.RetryCount = 0
				end
				var.Set('StatusText','Start Action, '..as.msg..' failed.')
				var.Set(as.var..'Status', as.failed)
			end	
		else
			var.Set(as.var..'Status', as.failed)
			log.Debug("CarNet_StartAction, pending request, ignoring  : "..request)
		end
	elseif request:sub(1,4) == 'poll' then
		-- Try up to nine poll requests 10 or 30 seconds apart depending on number of pending notifications.
		local npoll = tonumber(request:sub(-1) or 9)
		local deb_stat = ''
		if npoll < 9 then
			var.Set('StatusText','Update Car Status in progress....'..npoll)
			local cde, res = myModule.Command('getNotifications')
			if cde == 200 then
				log.Debug('getNotifications result : '..res)
				local rjs = json.decode(res) 
				if rjs.errorCode == '0' then 
					if rjs.actionNotification then 
						processNotification(rjs.actionNotification,1,npoll+1)
					elseif rjs.actionNotificationList then 
						for i = 1, #rjs.actionNotificationList do
							processNotification(rjs.actionNotificationList[i],#rjs.actionNotificationList,npoll+1)
						end	
					else	
						-- Got empty response with only errorCode : 0, check for next
						luup.call_delay("CarNet_StartAction", math.floor(pD.PollDelay/2), 'poll'..npoll+1)
					end	
				else
					deb_stat = 'getNotifications failed result : '..res
				end	
			else
				deb_stat = 'getNotifications failed result : '..res
			end
		else
			deb_stat = 'getNotifications did not return a SUCCEEDED within expected time window.'
		end
		-- See if things failed
		if deb_stat ~= '' then
			log.Debug(deb_stat)
			log.Log(deb_stat,5)
			-- See if we should retry the action
			local retry = var.GetNumber("ActionRetries")
			if pD.RetryCount < retry then
				luup.call_delay("CarNet_StartAction", pD.RetryDelay, pD.PendingAction)
				pD.RetryCount =  pD.RetryCount + 1
				myModule.SetStatusMessage('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
				log.Debug('Retry #'..pD.RetryCount..' of failed '..pD.PendingAction)
				local as = actionStateMap[pD.PendingAction]
				if as then var.Set(as.var..'Status', as.failed) end
			else	
				myModule.SetStatusMessage()
				local as = actionStateMap[pD.PendingAction]
				if as then
					var.Set(as.var..'Status', as.failed)
					var.Set('StatusText','Start Action, '..as.msg..' failed.')
				else
					var.Set('StatusText','Update Action Status failed.')
				end
				log.Debug('Retries #'..pD.RetryCount..' of failed '..pD.PendingAction.." all failed.")
				pD.PendingAction = ''
				pD.RetryCount = 0
			end	
		end	
	else	
		log.Debug("CarNet_StartAction, unknown request : "..(request or ''))
	end
	log.Debug("CarNet_StartAction, leave")
end

-- Global routine for polling e-Manager status when activity is running 
function CarNet_PollEManager()
	log.Debug("CarNet_PollEManager, enter")
	
	-- See if request is one of the commands
	local status, res = myModule.UpdateCarEManager()
	if status then
		log.Debug('getEManager succeeded')
		local pol = var.Get("PollSettings")
		local cs = var.GetNumber("ChargeStatus")
		local cls= var.GetNumber("ClimateStatus")
		local ws = var.GetNumber("WindowMeltStatus")
		local pol_t = {}
		string.gsub(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
		if #pol_t > 1 then 
			-- If an action is active and we have remaining time continue to poll
			if cs == 1 or cls == 1 or sw == 1 then 
				log.Debug('Schedule CarNet_PollEManager : '..tonumber(pol_t[1]) * 60)
				luup.call_delay("CarNet_PollEManager", tonumber(pol_t[1]) * 60)
			else	
				myModule.SetStatusMessage()
			end
		end
	else
		myModule.SetStatusMessage()
		log.Debug('UpdateEManager failed result : '..res)
	end
	log.Debug("CarNet_PollEManager, leave")
end

-- Initialize plug-in
function CarNetModule_Initialize()
	pD.DEV = lul_device

	-- start Utility API's
	log = logAPI()
	var = varAPI()
	var.Initialize(pD.SIDS.MODULE, pD.DEV)
	log.Initialize(pD.Description, var.GetNumber("LogLevel"), true)

	log.Log("device #" .. pD.DEV .. " is initializing!",3)

	-- See if we are running on openLuup. If not stop.
	if (luup.version_major == 7) and (luup.version_minor == 0) then
		pD.onOpenLuup = true
		log.Log("We are running on openLuup!!")
	else	
		luup.set_failure(1, pD.DEV)
		return true, "Incompatible with platform.", pD.Description
	end
		
	-- See if user disabled plug-in 
	if (var.GetAttribute("disabled") == 1) then
		log.Log("Init: Plug-in version "..pD.Version.." - DISABLED",2)
		-- Now we are done. Mark device as disabled
		var.Set("DisplayLine2","Plug-in disabled", pD.SIDS.ALTUI)
		luup.set_failure(0, pD.DEV)
		return true, "Plug-in Disabled.", pD.Description
	end	

	myCarNet = CarNetAPI()
	myModule = CarNetModule()

	myModule.Initialize()
	myCarNet.Initialize()
	myModule.SetStatusMessage()

	-- Set watches on email and password as userURL needs to be erased when changed
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Email", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Password", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Language", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "LogLevel", pD.DEV)
		
	-- Start polling loop
	luup.call_delay("CarNet_UpdateStatus", 36)

	log.Log("CarNetModule_Initialize finished ",10)
	luup.set_failure(0, pD.DEV)
end

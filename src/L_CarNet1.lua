--[[
	Module L_CarNet1.lua
	
	Written by R.Boer. 
	V1.1, 4 February 2018

	This plug-in emulates a browser accessing the VolksWagen Carnet portal www.volkswagen-car-net.com.
	A valid CarNet registration is required.
	
	At this moment only openLuup is supported provided it has LuaSec 0.7 installed. With LuaSec 0.5 the portal login will fail.
]]

local ltn12 	= require("ltn12")
local json 		= require("dkjson")
local https     = require("ssl.https")

local pD = {
	Version = '1.0',
	Debug = true,
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
	Plugin_Disabled = false,
	LogLevel = 10,
	lastVsrReqStarted = 0
}

local actionStateMap = {
	['startCharge'] 	= { var = 'Charge', succeed = 1, failed =0, msg = 'charging start', emanager = true },
	['stopCharge'] 		= { var = 'Charge', succeed = 0, failed = 1, msg = 'charging stop', emanager = true },
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
		local value = luup.attr_get("disabled", tonumber(device or def_dev))
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
local def_level = 3
local def_prefix = ''
local def_debug = false

	local function _init(prefix, level, deb)
		def_level = level
		def_prefix = prefix
		def_debug = deb
	end	

	local function _log(text, level) 
		local level = (level or 10)
		if (def_level >= level) then
			if (level == 10) then level = 50 end
			luup.log(def_prefix .. ": " .. text or "no text", (level or 50)) 
		end	
	end	
	
	local function _debug(text)
		if def_debug then
			luup.log(def_prefix .. "_debug: " .. text or "no text", 50) 
		end	
	end
	
	return {
		Initialize = _init,
		Log = _log,
		Debug = _debug
	}
end 

-- Interfaces to system
local function SetSessionDetails(userURL,token,sessionid)
	var.Set("userURL",(userURL or ''))
	var.Set("Token",(token or ''))
	var.Set("SessionID",(sessionid or ''))
end
local function GetSessionDetails()
	local userURL = var.Get("userURL")
	local token = var.Get("Token")
	local sessionid = var.Get("SessionID")
	return userURL,token,sessionid
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
	
	local port_host = "www.volkswagen-car-net.com"
	local HEADERS = { 
		['accept'] = 'application/json, text/plain, */*',
		['content-type'] = 'application/json;charset=UTF-8',
		['user-agent'] = 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:57.0) Gecko/20100101 Firefox/57.0' 
	}
	
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
	
	-- Handle post header x-www-form-urlencoded encoding
	local function _postencodepart(s)
		return s and (s:gsub("%W", function (c)
			if c ~= "." and c ~= "_" then
				return string.format("%%%02X", c:byte());
			else
				return c;
			end
		end));
	end
	local function postencode(p_data)
		local result = {};
		if p_data[1] then -- Array of ordered { name, value }
			for _, field in ipairs(p_data) do
				table.insert(result, _postencodepart(field[1]).."=".._postencodepart(field[2]));
			end
		else -- Unordered map of name -> value
			for name, value in pairs(p_data) do
				table.insert(result, _postencodepart(name).."=".._postencodepart(value));
			end
		end
		return table.concat(result, "&");
	end

	-- HTTPs Get request
	local function HttpsGet(strURL,ReqHdrs)
		local result = {}
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
		if PostData then
			-- We pass JSONs as string as they are simple in this application
			if type(PostData) == 'string' then
				ReqHdrs["content-type"] = 'application/json;charset=UTF-8'
				request_body=PostData
			else	
				ReqHdrs["content-type"] = 'application/x-www-form-urlencoded'
				request_body=postencode(PostData)
			end
			ReqHdrs["content-length"] = string.len(request_body)
		else	
			ReqHdrs["content-length"] = '0'
		end  
		local bdy,cde,hdrs,stts = https.request{
			url=strURL, 
			method='POST',
			sink=ltn12.sink.table(result),
			source = ltn12.source.string(request_body),
			headers = ReqHdrs
		}
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
		return '{"errorCode":"'..cde..'", "actionNotification" : {"actionState":"FAILED","actionType":"'..at..'","errorTitle":"'..ti..'", "errorMessage":"'..ms..'" }}'
	end

	-- Login to portal
	local function _portal_login(email, password, cc)
		log.Debug('Enter PortalLogin :'.. email)

		local sec_host = 'security.volkswagen.com'
		local bdy,cde,hdrs,result,ref_url, lg_url
		local cookie_Init = ''
		local cookie_JS = ''
		local isoLC = _getlanguacode(cc)
		
		-- Fixed URLs to use in order
		local URLS = { 
			'https://' .. port_host .. '/portal/'..isoLC..'/web/guest/home', 
			'https://' .. port_host .. '/portal/'..isoLC..'/web/guest/home/-/csrftokenhandling/get-login-url',
			'https://' .. sec_host  .. '/ap-login/jsf/login.jsf',
			'https://' .. port_host .. '/portal/'..isoLC..'/web/guest/complete-login'
		}
		-- Base Headers to start with
		local AUTHHEADERS = {
			['host'] = port_host,
			['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
			['accept-language'] = 'en-US,en;q=0.5',
			['user-agent'] = 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:57.0) Gecko/20100101 Firefox/57.0', 
			['connection'] = 'keep-alive',
			['upgrade-insecure-requests'] = '1'
		}

		-- Clone header table so we can start over as needed
		local function header_clone(orig)
			local copy
			if type(orig) == 'table' then
				copy = {}
				for orig_key, orig_value in pairs(orig) do
					copy[orig_key] = orig_value
				end
			else -- number, string, boolean, etc
				copy = orig
			end
			return copy
		end
		
		-- Request landing page and get CSFR Token:
		local req_hdrs = header_clone(AUTHHEADERS)
		-- Initial logon. E.g. "https://www.volkswagen-car-net.com/portal/nl_NL/web/guest/home"
		bdy,cde,hdrs,result = HttpsGet(URLS[1],req_hdrs)
		if cde ~= 200 then return '', '1', 'Incorrect response code ' .. cde .. ' expect 200' end
		if (hdrs and hdrs['set-cookie']) then 
			cookie_JS = string.match(hdrs['set-cookie'],'JSESSIONID=([%w%.]+); Path=')
		if cookie_JS then
				cookie_Init = 'JSESSIONID='.. cookie_JS ..'; GUEST_LANGUAGE_ID='..isoLC..'; COOKIE_SUPPORT=true; CARNET_LANGUAGE_ID='..isoLC..'; VW_COOKIE_AGREEMENT=true'
			end	
		end
		-- Get x-csrf-token from html result
		local csrf = string.match(result[1],'<meta name="_csrf" content="(%w+)"/>')
		if not csrf then return '', '1.2', 'No token found' end

		-- Get login page. E.g. "https://www.volkswagen-car-net.com/portal/nl_NL/web/guest/home/-/csrftokenhandling/get-login-url"
		req_hdrs['referer'] = URLS[1]
		req_hdrs['x-csrf-token'] = csrf
		req_hdrs['accept'] = 'application/json, text/plain, */*'
		req_hdrs['cookie'] = cookie_Init
		bdy,cde,hdrs,result = HttpsPost(URLS[2],req_hdrs)
		if cde ~= 200 then return '', '2', 'Incorrect response code ' .. cde .. ' expect 200' end
		local responseData = json.decode(table.concat(result))
		lg_url = responseData.loginURL.path
		if not lg_url then return '', '2.1', 'Missing redirect location in response' end

		-- Get oauth2 page. E.g. "https://security.volkswagen.com/as/authorization.oauth2?apTargetResource...."
		req_hdrs = header_clone(AUTHHEADERS)
		if not userURL then req_hdrs['referer'] = URLS[1] end
		req_hdrs['cookie'] = 'PF=CZXp7A7tbc0Cn6Af6Fu4eP' -- Dummy value
		req_hdrs['accept-encoding'] = 'gzip, deflate, br'
		req_hdrs['host'] = sec_host
		-- stops here unless you install luasec 0.7 as SNI is not supported by luasec 0.5 or 0.6. Show stopper for Vera it seems.
		bdy,cde,hdrs,result = HttpsGet(lg_url,req_hdrs)
		local cookie_PF = ''
		if (hdrs and hdrs['set-cookie']) then 
			cookie_PF = string.match(hdrs['set-cookie'],'PF=(%w+);')
		end
		if cde ~= 302 then return '', '3', 'Incorrect response code ' .. cde .. ' expect 302'   end
		ref_url = hdrs.location
		if not ref_url then return '', '3.1', 'Missing redirect location in return header' end
	
		-- now get actual login page and get session id and ViewState. E.g. "https://security.volkswagen.com/ap-login/jsf/login.jsf?resume=/as...."
		req_hdrs = header_clone(AUTHHEADERS)
		if userURL then 
			req_hdrs['cookie'] = 'PF='..cookie_PF
		else	
			req_hdrs['referer'] = URLS[1] 
			req_hdrs['cookie'] = 'JSESSIONID='.. cookie_JS ..'; PF='..cookie_PF
		end
		req_hdrs['host'] = sec_host
		bdy,cde,hdrs,result = HttpsGet(ref_url,req_hdrs)
		if cde ~= 200 then return '', '4', 'Incorrect response code ' .. cde .. ' expect 200'   end
		if (hdrs and hdrs['set-cookie']) then 
			cookie_JS = string.match(hdrs['set-cookie'],'JSESSIONID=([%w%.]+); Path=')
		end
		local view_state = string.match(table.concat(result),'name="javax.faces.ViewState" id="j_id1:javax.faces.ViewState:0" value="([%-:0-9]+)"')
		if not view_state then return '', '4.1', 'Missing ViewState in result'  end

		-- Submit login details
		req_hdrs = header_clone(AUTHHEADERS)
		req_hdrs['accept'] = '*/*'
		req_hdrs['faces-request'] = 'partial/ajax'
		req_hdrs['referer'] = ref_url
		req_hdrs['cookie'] = 'JSESSIONID='.. cookie_JS ..'; PF='..cookie_PF
		req_hdrs['host'] = sec_host

		local post_data = { 
			{'loginForm', 'loginForm'},
			{'loginForm:email', (email or '')},
			{'loginForm:password', (password or '')},
			{'loginForm:j_idt19', ''},
			{'javax.faces.ViewState', (view_state or '')},
			{'javax.faces.source', 'loginForm:submit'},
			{'javax.faces.partial.event', 'click'},
			{'javax.faces.partial.execute', 'loginForm:submit loginForm'},
			{'javax.faces.partial.render', 'loginForm'},
			{'javax.faces.behavior.event', 'action'},
			{'javax.faces.partial.ajax','true'}
		}
	
		bdy,cde,hdrs,result = HttpsPost(URLS[3], req_hdrs, post_data)
		if cde ~= 200 then return '', '5', 'Incorrect response code ' .. cde .. ' expect 200' end
		local cookie_SO = ''
		if (hdrs and hdrs['set-cookie']) then 
			cookie_SO = string.match(hdrs['set-cookie'],'SsoProviderCookie=(.+); Domain=.volkswagen.com;')
		end
		if not cookie_SO then return '', '5.1', 'Missing SsoProviderCookie in return set-cookie' end
		local ref_url1 =string.gsub(string.match(table.concat(result),'<redirect url="([^"]*)"></redirect>'),'&amp;','&')
		if not ref_url1 then return '', '5.2', 'Missing redirect location in result'  end

		-- Call authorization. E.g. "https://security.volkswagen.com/as/WkHwr/resume/as/authorization.ping?apTarge....."
		req_hdrs = header_clone(AUTHHEADERS)
		req_hdrs['cookie'] = 'PF='..cookie_PF..'; SsoProviderCookie='..cookie_SO
		req_hdrs['accept-encoding'] = 'gzip, deflate, br'
		req_hdrs['referer'] = ref_url
		req_hdrs['host'] = sec_host
		bdy,cde,hdrs,result = HttpsGet(ref_url1,req_hdrs)
		if cde ~= 302 then return '', '6', 'Incorrect response code ' .. cde .. ' expect 302' end
		local ref_url2 = hdrs.location
		if not ref_url2 then return '', '6.1', 'Missing redirect location in return header' end
		local code = string.match(ref_url2,'code=([^"]*)&')

		-- Next step. E.g. "https://www.volkswagen-car-net.com/portal/nl_NL/web/guest/complete-login?...."
		req_hdrs = header_clone(AUTHHEADERS)
		req_hdrs['referer'] = ref_url
		req_hdrs['accept-encoding'] = 'gzip, deflate, br'
		bdy,cde,hdrs,result = HttpsGet(ref_url2,req_hdrs)
		if cde ~= 200 then return '', '7', 'Incorrect response code ' .. cde .. ' expect 200' end
	
		-- Complete last login step. E.g. "https://www.volkswagen-car-net.com/portal/nl_NL/web/guest/complete-login?p_auth=...."
		req_hdrs = header_clone(AUTHHEADERS)
		req_hdrs['referer'] = ref_url2
		req_hdrs['cookie'] = cookie_Init
		req_hdrs['accept-encoding'] = 'gzip, deflate, br'
		post_data = { 
			{'_33_WAR_cored5portlet_code', code },
			{'_33_WAR_cored5portlet_landingPageUrl', ''}
		}
		bdy,cde,hdrs,result = HttpsPost(URLS[4].. '?p_auth=' .. csrf .. '&p_p_id=33_WAR_cored5portlet&p_p_lifecycle=1&p_p_state=normal&p_p_mode=view&p_p_col_id=column-1&p_p_col_count=1&_33_WAR_cored5portlet_javax.portlet.action=getLoginStatus',req_hdrs, post_data)
		if cde ~= 302 then return '', '8', 'Incorrect response code ' .. cde .. ' expect 302' end
		if (hdrs and hdrs['set-cookie']) then 
			cookie_JS = string.match(hdrs['set-cookie'],'JSESSIONID=([%w%.]+); Path=')
		end
		if not cookie_JS then return '', '8.1', 'Missing JSESSIONID in return set-cookie' end
		ref_url3 = hdrs.location
		if not ref_url3 then return '', '8.2', 'Missing redirect location in return header' end

		-- Go to home page or get command on reconnect
		req_hdrs = header_clone(AUTHHEADERS)
		req_hdrs['referer'] = ref_url2
		req_hdrs['cookie'] = 'JSESSIONID='.. cookie_JS ..'; GUEST_LANGUAGE_ID='..isoLC..'; COOKIE_SUPPORT=true; CARNET_LANGUAGE_ID='..isoLC
		bdy,cde,hdrs,result = HttpsGet(ref_url3,req_hdrs)
		if cde ~= 200 then return '', '9', 'Incorrect response code ' .. cde .. ' expect 200' end
	
		--We have a new CSRF
		csrf = string.match(result[1],'<meta name="_csrf" content="(%w+)"/>')
		-- done!!!! we are in at last
		log.Debug('Login done. Token : '..csrf)	
		return ref_url3, csrf, cookie_JS
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
	local function _sendcommand(command, token, sessionid, base_url)
		log.Debug('Enter SendCommand :'.. command)
		local cm_url = commands[command].url
		local cm_data = commands[command].json
		if cm_url then 
			local isoLC = _getlanguacode(cc)
			local req_hdrs = HEADERS
			req_hdrs['x-csrf-token'] = token
			req_hdrs['origin'] = 'https://'..port_host
			req_hdrs['referer'] = _url
			req_hdrs['cookie'] = 'JSESSIONID='.. sessionid ..'; GUEST_LANGUAGE_ID='..isoLC..'; COOKIE_SUPPORT=true; CARNET_LANGUAGE_ID='..isoLC
			local bdy,cde,hdrs,result = HttpsPost(base_url..cm_url,req_hdrs,cm_data)
			-- We have a redirect because session expired, so tell caller to login again
			if cde == 302 then
				return cde
			elseif cde == 200 then
				return cde, table.concat(result)
			else
				log.Log('Incorrect responce code '..cde,5)
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
		var.Default("Email")
		var.Default("Password")
		var.Default("LogLevel", pD.LogLevel)
		var.Default("userURL")
		var.Default("Token")
		var.Default("SessionID")
		var.Default("Language", "GB")
		var.Default("PollSettings", '5,60,120,15') -- Active, Home Idle, Away Idle, FastPoll location
		var.Default("LocationHome")
		var.Default("CarName")
		var.Default("PackageService")
		var.Default("PackageServiceActDate")
		var.Default("PackageServiceExpDate")
		var.Default("PackageServiceExpired")
		var.Default("PackageServiceExpireInAmonth")
		var.Default("LastFLCPoll", 0)
		var.Default("ChargeStatus", "0")
		var.Default("ClimateStatus", "0")
		var.Default("WindowMeltStatus", "0")
		var.Default("ChargeMessage")
		var.Default("ClimateMessage")
		var.Default("WindowMeltMessage")
		var.Default("DoorsStatus")
		var.Default("WindowsStatus")
		var.Default("SunroofStatus")
		var.Default("LightsStatus")
		var.Default("HoodStatus")
		var.Default("Mileage")
		var.Default("Location")
		var.Default("LocationHome")
		var.Default("FastPollLocations")
		var.Default("AtLocationRadius", 0.5)
		var.Default("PowerSupplyConnected")
		var.Default("IconSet",0)
		

		return true
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
			local userURL,token,sessionid = myCarNet.PortalLogin(email, password, cc)
			if userURL ~= '' then
				SetSessionDetails(userURL, token, sessionid)
				var.Set('LastLogin', os.time())
				return 200, userURL, token, sessionid
			else
				log.Log('Unable to login. errorCode : '..token..', errorMessage : '..sessionid ,3)
				return 404, "PORTAL_LOGIN","Login to CarNet Portal failed "..token,sessionid
			end
		else
			log.Log('Configration not complete',5)
			return 404, 'PLUGIN_CONFIG','Plug-in setup not complete','Missing email, password and/or language, please complete setup.'
		end
	end
	
	local function _command(command)
		local userURL, token, sessionid = GetSessionDetails()
		local cde
		if userURL == '' or token == '' or sesionid == '' then
			-- We need to login first.
			log.Debug('No session yet, need to login')
			cde, userURL, token, sessionid = _login()
			if cde ~= 200 then
				return cde, myCarNet.BuildErrorMessage(cde, userURL, token, sessionid)
			end	
		end	
		log.Debug('Sending command : '..command)
		local cde, res = myCarNet.SendCommand(command, token, sessionid, userURL)
		if cde == 200 then
			log.Log('Command result : Code ; '..cde..', Response ; '.. string.sub(res,1,30))
			log.Debug(res)	
			return cde, res
		elseif cde == 302 then
			-- Session expired. We need to login again
			log.Debug('Session exipred, need to login')
			cde, userURL, token, sessionid = _login()
			if cde ~= 200 then
				return cde, myCarNet.BuildErrorMessage(cde, userURL, token, sessionid)
			else	
				cde, res = myCarNet.SendCommand(command, token, sessionid, userURL)
				log.Log('Command result : Code ; '..cde..', Response ; '.. string.sub(res,1,30))
				log.Debug(res)	
				return cde, res
			end	
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
	local function _update_car_status(rjs)
		local n_doors = 2
		
		local function buildStatusText(item, drs, lckd)
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
				return table.concat(txt_t, ', ')..' is '
			elseif #txt_t < drs then
				return table.concat(txt_t, ', ')..' are '
			else	
				return 'All are '
			end
		end
		
		if rjs.vehicleStatusData then
			local vsd = rjs.vehicleStatusData
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
					var.Set('LocksStatus','All locked')
				end
			end	
			-- Get mileage and refresh time details
			if vsd.headerData then
				if vsd.headerData.mileage then var.Set('Mileage',vsd.headerData.mileage) end
				if vsd.headerData.lastRefreshTime then 
					var.Set('LastVsrRefreshTime',vsd.headerData.lastRefreshTime[1]..', '..vsd.headerData.lastRefreshTime[2]) 
				end
			end
			-- Get Battery details if available, get from e-manager
			--if vsd.batteryLevel then var.Set("BatteryLevel", vsd.batteryLevel , pD.SIDS.HA) end
			--if vsd.batteryRange then var.Set("BatteryRange", vsd.batteryRange) end
			return true
		else
			return false
		end
	end

	-- We have an updated car location
	local function _update_car_location(rjs)
		if rjs.position then
			local lat = rjs.position.lat 
			local lng = rjs.position.lng
			var.Set('Location', 'Lat : '..(lat or '?')..', Long : '..(lng or '?'))
			-- Compare to home location and set/clear at home flag when within 500 m
			lat = tonumber(lat) or luup.latitude
			lng = tonumber(lng) or luup.longitude
			local radius = tonumber(var.Get('AtLocationRadius'),10) or 0.5
			if _distance(lat,lng, luup.latitude, luup.longitude) < radius then
				var.Set('LocationHome', 1)
			else
				var.Set('LocationHome', 0)
			end
			return true
		else
			return false
		end
	end
	
	-- We have updated e-manager data
	local function _update_car_emanager(rjs)
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
			return true
		else
			return false
		end
	end

	-- We have updated car details data
	local function _update_car_details(rjs)
		if rjs.fullyLoadedVehiclesResponse then
			local data 
			-- See what entry holds the data. Not sure why my car is in vehiclesNotFullyLoaded and I do not know if completeVehicles will have the same data
			-- You should also get more details from this data when you have more then one car on the account. Not supporting this for now. Single car only.
			if #rjs.fullyLoadedVehiclesResponse.completeVehicles == 1 then data = rjs.fullyLoadedVehiclesResponse.completeVehicles[1] end
			if #rjs.fullyLoadedVehiclesResponse.vehiclesNotFullyLoaded == 1 then data = rjs.fullyLoadedVehiclesResponse.vehiclesNotFullyLoaded[1] end
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
				return true
			else
				return false
			end
		else
			return false
		end
	end
	
	-- Trigger an update of the car status by sending RequestVsr now
	local function _poll()
		log.Debug("Poll, enter")
		CarNet_UpdateStatus('loop')
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
		CalculateDistance = _distance,
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
		local lev = tonumber(strNewVal, 10) or '10'
		if lev > 10 then
			pD.Debug = true
			pD.LogLevel = 10
		else
			pD.Debug = false
			pD.LogLevel = lev
		end
	end
end

-- Global routine for polling car status. First send RequestVsr and then wait for updated status response.
function CarNet_UpdateStatus(request)
	local result = true
	log.Debug("CarNet_UpdateStatus, enter for " .. request)
	-- After 24 hrs we do a getFullyLoadedCars command again
	local lfp = os.time() - var.GetNumber('LastFLCPoll')
	if request == 'loop' and lfp >  86400 then
		var.Set('DisplayLine2', 'Refreshing status...', pD.SIDS.ALTUI)
		-- Get high level car end CatNet subscription details, run this once a day
		cde, res = myModule.Command('getFullyLoadedCars')
		if cde == 200 then
			log.Debug('getFullyLoadedCars result : '..res)
			local rjs = json.decode(res)
			if rjs.errorCode == "0" then
				if myModule.UpdateCarDetails(rjs) then 
					var.Set('LastFLCPoll', os.time())
			
					-- Next update car details in five seconds
					luup.call_delay("CarNet_UpdateStatus", 5, 'loop')
				else
					log.Log('getFullyLoadedCars failed reading data : '..res,3)
				end
			end
		else
			log.Log('getFullyLoadedCars failed result : '..res)
			result = false
		end
	elseif request == 'loop' then
		-- See if we have a pending request that started less than five minutes ago. Do not start a second one.
		if (os.time() - pD.lastVsrReqStarted) < 300 then
			log.Debug("CarNet_UpdateStatus, we have a double request within five minutes. Not starting a new.")
			return false
		end
		var.Set('DisplayLine2', 'Refreshing status...', pD.SIDS.ALTUI)
		local pol = var.Get("PollSettings")
		local cs = var.GetNumber("ChargeStatus")
		local cls= var.GetNumber("ClimateStatus")
		local ws = var.GetNumber("WindowMeltStatus")
		local pol_t = {}
		local next_pol = 60
		string.gsub(pol..",","(.-),", function(c) pol_t[#pol_t+1] = c end)
		if #pol_t > 2 then 
			-- If an action is active, use second poll time
			if cs == 1 or cls == 1 or sw == 1 then 
				next_pol = pol_t[1]
			else
			-- If not active, see if car is in atHome range or not
			if var.GetNumber('LocationHome') == 1 then
				next_pol = pol_t[2]
			else	
				next_pol = pol_t[3]
				-- See if we are at a fast poll location
				local fpl = json.decode(var.Get('FastPollLocations'))
				if fpl then
					if #fpl == 0 then
						if _distance(fpl.lat, fpl.lng, luup.latitude, luup.longitude) < radius then
							next_pol = pol_t[4]
						end
					else
						for k,v in pairs(fpl) do
							if _distance(v.lat, v.lng, luup.latitude, luup.longitude) < radius then
								next_pol = pol_t[4]
								break
							end
						end
					end
				end
			end
		end
	
		-- Schedule next update request
		if (next_pol == 0) then next_poll = 60 end
		luup.call_delay("CarNet_UpdateStatus", next_pol * 60, 'loop') end

		-- Send update request to car, then wait 30 seconds to see if we have a result
		pD.lastVsrReqStarted = os.time()
		local cde, res = myModule.Command('getRequestVsr')
		if cde == 200 then
			log.Debug('getRequestVsr result : '..res)
			local rjs = json.decode(res) 
			if rjs.errorCode == '0' then 
				var.Set('StatusText','Update Car Status in progress....')
				luup.call_delay("CarNet_UpdateStatus", 30, 'poll0') 
			else
				var.Set('StatusText','Update Car Status request failed.')
				result = false
			end
		else
			var.Set('StatusText','Update Car Status request failed.')
			result = false
		end
	elseif request:sub(1,4) == 'poll' then
		-- Try up to five poll requests 30 seconds apart
		local npoll = tonumber(request:sub(-1) or 4)
		if npoll < 4 then
			var.Set('StatusText','Update Car Status in progress....'..npoll)
			local cde, res = myModule.Command('getVsr')
			if cde == 200 then
				log.Debug('getVsr result : '..res)
				local rjs = json.decode(res) 
				if rjs.errorCode == '0' then 
					local status = rjs.vehicleStatusData.requestStatus
					if status == 'REQUEST_IN_PROGRESS' then
						luup.call_delay("CarNet_UpdateStatus", 30, 'poll'..(npoll + 1)) 
					elseif status == 'REQUEST_SUCCESSFUL' then
						-- Refresh VSR status	
						myModule.UpdateCarStatus(rjs)
						
						-- Next get car location long-lat.
						cde, res = myModule.Command('getLocation')
						if cde == 200 then
							log.Debug('getLocation result : '..res)
							local rjs = json.decode(res)
							if rjs.errorCode == "0" then
								myModule.UpdateCarLocation(rjs)
							end
						else
							log.Debug('getLocation failed result : '..res)
						end
						-- If we have eManager, get its status
						if var.Get('EManager') == '1' then
							local cde, res = myModule.Command('getEManager')
							if cde == 200 then
								log.Debug('getEManager result : '..res)
								local rjs = json.decode(res)
								if rjs.errorCode == "0" then
									myModule.UpdateCarEManager(rjs)
								end
							else
								log.Debug('getEManager failed result : '..res)
							end
						end
						var.Set('DisplayLine2', '', pD.SIDS.ALTUI)
						var.Set('StatusText','Update Car Status complete.')
						local pc = var.GetNumber("PollOk", pD.SIDS.ZW) + 1
						var.Set("PollOk", pc, pD.SIDS.ZW)
						pD.lastVsrReqStarted = 0
					else
						-- Late/rogue getVsr response without status
						var.Set('DisplayLine2', '', pD.SIDS.ALTUI)
						var.Set('StatusText','Update Car Status finished.')
						pD.lastVsrReqStarted = 0
					end	
				else
					log.Debug('getVsr failed result : '..res)
					result = false
				end	
			else
				log.Debug('getVsr failed result : '..res)
				result = false
			end
		else
			log.Debug('getVsr did not return a REQUEST_SUCCESSFULL withing 120 seconds.')
			var.Set('StatusText','Update Car Status timed out.')
			result = false
		end
	end
	if not result then
		local pc = var.GetNumber("PollNoReply", pD.SIDS.ZW) + 1
		var.Set("PollNoReply", pc, pD.SIDS.ZW)
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
						var.Set('DisplayLine2', '', pD.SIDS.ALTUI)
						-- Request eManager status if required
						if as.emanager then
							local cde, res = myModule.Command('getEManager')
							if cde == 200 then
								log.Debug('getEManager result : '..res)
								local rjs = json.decode(res)
								if rjs.errorCode == "0" then
									myModule.UpdateCarEManager(rjs)
								end
							else
								log.Debug('getEManager failed result : '..res)
							end
						end
					else
						log.Debug('Request '..ts..' not defined in actionStateMap.')
					end
				else
					log.Debug('actionType '..nt.actionType..' not defined in actionTypeMap.')
				end
			elseif nt.actionState == 'FAILED' or nt.actionState == 'FAILED_DELAYED' then
				local ts = actionTypeMap[nt.actionType]
				if ts then
					local as = actionStateMap[ts]
					if as then
						var.Set('DisplayLine2', 'Last action failed', pD.SIDS.ALTUI)
						var.Set(as.var..'Status', as.failed)
						var.Set(as.var..'Message', 'Failed: '..nt.errorTitle)
						var.Set('StatusText','Start Action, '..as.msg..' failed.')
					else
						log.Debug('Request '..ts..' not defined in actionStateMap.')
					end
				else
					log.Debug('actionType '..nt.actionType..' not defined in actionTypeMap.')
				end
			else	
				-- Action(s) have not yet completed, schedule next poll. Do more frequent if we have more actions pending.
				local pt = (((nnt == 1) and 30) or 10)
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
		var.Set('DisplayLine2', 'Starting Action...', pD.SIDS.ALTUI)
		var.Set('StatusText','Start Action, sending command : '..request)
		var.Set(as.var..'Message', "Pending...")
		var.Set(as.var..'Status', as.succeed)
		local cde, res = myModule.Command(request)
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
				var.Set(as.var..'Status', as.failed) 
				var.Set('StatusText','Start Action, '..as.msg..' failed.')
			end	
		else	
			var.Set(as.var..'Status', as.failed)
			var.Set('StatusText','Start Action, '..as.msg..' failed.')
		end	
	elseif request:sub(1,4) == 'poll' then
		-- Try up to nine poll requests 10 or 30 seconds apart depending on number of pending notifications.
		local npoll = tonumber(request:sub(-1) or 9)
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
						luup.call_delay("CarNet_StartAction", 10, 'poll'..npoll+1)
					end	
					var.Set('StatusText','Update Action Status complete.')
				else
					log.Debug('getNotifications failed result : '..res)
				end	
			else
				log.Debug('getNotifications failed result : '..res)
			end
		else
			log.Log('getNotifications did not return a SUCCEEDED within expected time window.',5)
			var.Set('StatusText','Update Action Status timed out.')
		end
	else	
		log.Debug("CarNet_StartAction, unknown request : "..(request or ''))
	end
	log.Debug("CarNet_StartAction, leave")
end

-- Initialize plug-in
function CarNetModule_Initialize()
	pD.DEV = lul_device

	-- start Utility API's
	log = logAPI()
	var = varAPI()
	var.Initialize(pD.SIDS.MODULE, pD.DEV)
	log.Initialize(pD.Description, pD.LogLevel, pD.Debug)

	log.Log("device #" .. pD.DEV .. " is initializing!",3)
	-- See if we are running on openLuup. If not stop.
	if (luup.version_major == 7) and (luup.version_minor == 0) then
		pD.onOpenLuup = true
		log.Log("We are running on openLuup!!")
	else	
		luup.set_failure(1, pD.DEV)
		return true, "Incompatible with platform.", pD.Description
	end
		
	--	_registerWithAltUI()

	
	-- See if user disabled plug-in 
	if (var.GetAttribute("disabled") == 1) then
		log.Log("Init: Plug-in version "..pD.Version.." - DISABLED",2)
--		pD.Plugin_Disabled = true
--			var.Set("LinkStatus", "Plug-in disabled")
		-- Now we are done. Mark device as disabled
		var.Set("DisplayLine2","Plug-in disabled", pD.SIDS.ALTUI)
		luup.set_failure(0, pD.DEV)
		return true, "Plug-in Disabled.", pD.Description
	end	

	myCarNet = CarNetAPI()
	myModule = CarNetModule()

	myModule.Initialize()
	myCarNet.Initialize()

	-- Set watches on email and password as userURL needs to be erased when changed
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Email", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Password", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "Language", pD.DEV)
	luup.variable_watch('CarNet_VariableChanged', pD.SIDS.MODULE, "LogLevel", pD.DEV)
		
	-- Start polling loop
	luup.call_delay("CarNet_UpdateStatus", 36, "loop")

	log.Log("CarNetModule_Initialize finished ",10)
	luup.set_failure(0, pD.DEV)
end

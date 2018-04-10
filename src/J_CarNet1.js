//# sourceURL=J_CarNet1.js
// openLuup "CarNet" Plug-in
// Written by R.Boer. 
// V1.7 9 March 2018
//
var CarNet = (function (api) {

	var MOD_SID = 'urn:rboer-com:serviceId:CarNet1';
	var moduleName = 'CarNet';

	// Forward declaration.
    var myModule = {};

    function _onBeforeCpanelClose(args) {
    }

    function _init() {
        // register to events...
        api.registerEventHandler('on_ui_cpanel_before_close', myModule, 'onBeforeCpanelClose');
    }

	function _showSettings() {
		_init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var panelHtml = '<div class="deviceCpanelSettingsPage">'
				+ '<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var pollIntervals = [{'value':'5','label':'5 Min'},{'value':'10','label':'10 Min'},{'value':'15','label':'15 Min'},{'value':'20','label':'20 Min'},{'value':'30','label':'30 Min'},{'value':'60','label':'60 Min'},{'value':'90','label':'90 Min'},{'value':'120','label':'120 Min'}];
				var pollSlow = [{'value':'120','label':'Two Hours'},{'value':'240','label':'Four Hours'},{'value':'1440','label':'24 Hours'}];
				var langCodes = [{'value':'BE-NL','label':'België'},{'value':'BE-FR','label':'Belgique'},{'value':'BA','label':'Bosnia and Herzegovina'},{'value':'BG','label':'България'},{'value':'CZ','label':'Česká republika'},{'value':'DK','label':'Danmark'},{'value':'DE','label':'Deutschland'},{'value':'EE','label':'Eesti'},{'value':'GR','label':'Ελλάδα'},{'value':'ES','label':'España'},{'value':'FR','label':'France'},{'value':'HR','label':'Hrvatska'},{'value':'IS','label':'Ísland'},{'value':'IE','label':'Ireland'},{'value':'IT','label':'Italia'},{'value':'LV','label':'Latvija'},{'value':'LT','label':'Lietuva'},{'value':'LU-FR','label':'Luxembourg'},{'value':'LU-DE','label':'Luxemburg'},{'value':'HU','label':'Magyarország'},{'value':'MT','label':'Malta'},{'value':'NL','label':'Nederland'},{'value':'NO','label':'Norge'},{'value':'AT','label':'Österreich'},{'value':'PL','label':'Polska'},{'value':'PT','label':'Portugal'},{'value':'RO','label':'România'},{'value':'CH','label':'Schweiz / Svizzera / Suisse'},{'value':'SI','label':'Slovenija'},{'value':'SK','label':'Slovenská republika'},{'value':'FI','label':'Suomi'},{'value':'SE','label':'Sverige'},{'value':'UA','label':'Україна'},{'value':'GB','label':'United Kingdom'}];
				var logLevel = [{'value':'1','label':'Error'},{'value':'2','label':'Warning'},{'value':'8','label':'Info'},{'value':'10','label':'Debug'},{'value':'11','label':'Test Debug'}];
				var retries = [{'value':'0','label':'None'},{'value':'1','label':'One'},{'value':'2','label':'Two'},{'value':'3','label':'Three'},{'value':'4','label':'Four'}];

				panelHtml += htmlAddInput(deviceID, 'CarNet Email', 30, 'Email') + 
				htmlAddInput(deviceID, 'CarNet Password', 30, 'Password')+
				htmlAddPulldown(deviceID, 'CarNet Language', 'Language', langCodes)+ 
				htmlAddPulldown(deviceID, 'Action retries', 'ActionRetries', retries)+
				htmlAddPulldown(deviceID, 'Poll Interval; Active', 'PI0', pollIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Home Idle', 'PI1', pollIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Away Idle', 'PI2', pollIntervals)+
				htmlAddPulldown(deviceID, 'Poll Interval; Vacation Idle', 'PI4', pollSlow)+
				htmlAddPulldown(deviceID, 'Poll Interval; Fast Locations', 'PI3', pollIntervals)+
				htmlAddInput(deviceID, 'Fast Poll Locations (lat,lng;lat,lng)', 30, 'FastPollLocations')+ 
				htmlAddInput(deviceID, 'No Poll time window (hh:mm-hh:mm)', 30, 'NoPollWindow')+ 
				htmlAddPulldown(deviceID, 'Log level', 'LogLevel', logLevel);
			}
			api.setCpanelContent(panelHtml);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.showSettings(): ' + e);
        }
	}
	
	function _showStatus() {
		_init();
        try {
			var deviceID = api.getCpanelDeviceId();
			var deviceObj = api.getDeviceObject(deviceID);
			var panelHtml = '<div class="deviceCpanelSettingsPage">'
				+ '<h3>Device #'+deviceID+'&nbsp;&nbsp;&nbsp;'+api.getDisplayedDeviceName(deviceID)+'</h3>';
			if (deviceObj.disabled === '1' || deviceObj.disabled === 1) {
				panelHtml += '<br>Plugin is disabled in Attributes.';
			} else {	
				var cn = varGet(deviceID, 'CarName');
				var lat = Number.parseFloat(varGet(deviceID, 'Latitude')).toFixed(4);
				var lng = Number.parseFloat(varGet(deviceID, 'Longitude')).toFixed(4);
				var clh = varGet(deviceID, 'LocationHome');
				var ppls = varGet(deviceID, 'PowerPlugLockState');
				var pps = varGet(deviceID, 'PowerPlugState');
				var psc = varGet(deviceID, 'PowerSupplyConnected');
				var drs = varGet(deviceID, 'DoorsStatus');
				var lcks = varGet(deviceID, 'LocksStatus');
				var mlg = varGet(deviceID, 'Mileage');
				var lts = varGet(deviceID, 'LightsStatus');
				var psed = varGet(deviceID, 'PackageServiceExpDate');
				var srs = varGet(deviceID, 'SunroofStatus');
				var wins = varGet(deviceID, 'WindowsStatus');
				var psm = 'Unknown';
				if (psc === '1') {
					psm = 'Charge power available';
				} else {
					if (pps === '1') {
						if (ppls === '1') {
							psm = 'Cable in car, but not in charge station'
						} else {
							psm = 'Cable in car, but not locked!!!!'
						}	
					} else {
						psm = 'Not connected'
					}
				}
				panelHtml += '<p><div class="col-12" style="overflow-x: auto;"><table class="table-responsive-OFF table-sm"><tbody>'+
					'<tr><td colspan="2">CarNet subscription name </td><td>'+cn+'</td></tr>'+
					'<tr><td> </td><td> </td><td></td></tr>'+
					'<tr><td>Milage </td><td>'+mlg+' Km</td></tr>'+
					'<tr><td> </td><td> </td><td></td></tr>'+
					'<tr><td>Car location </td><td>'+(clh==='1'?'Home':'Away')+'</td><td>Latitude : '+lat+', Longitude : '+lng+'</td></tr>'+
					'<tr><td>Power Status </td><td colspan="2">'+psm+'</td></tr>'+
					'<tr><td> </td><td> </td><td></td></tr>'+
					'<tr><td>Locks Status </td><td colspan="2">'+lcks+'</td></tr>'+
					'<tr><td>Doors Status </td><td colspan="2">'+drs+'</td></tr>'+
					'<tr><td>Windows Status </td><td colspan="2">'+wins+'</td></tr>'+
					'<tr><td>Lights Status </td><td colspan="2">'+(lts==='1'?'On':'Off')+'</td></tr>'+
					'<tr><td> </td><td> </td><td></td></tr>'+
					'<tr><td colspan="2">Subscription expiry date </td><td>'+psed+'</td><td></td></tr>'+
					'</tbody></table></div></p>';
			}	
			api.setCpanelContent(panelHtml);
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.showStatus(): ' + e);
        }
	}
	
	function  _updateVariable(vr,val) {
        try {
			var deviceID = api.getCpanelDeviceId();
			if (vr.startsWith('PI')) {
				var ps = varGet(deviceID,'PollSettings');
				var pa = ps.split(',');
				pa[Number(vr.charAt(2))] = val;
				varSet(deviceID,'PollSettings',pa.join(','));
			} else {
				varSet(deviceID,vr,val);
			}
        } catch (e) {
            Utils.logError('Error in '+moduleName+'.updateVariable(): ' + e);
        }
	}
	
	// Add a button html
	function htmlAddButton(di, cb, lb) {
		var html = '<div class="cpanelSaveBtnContainer labelInputContainer clearfix">'+	
			'<input class="vBtn pull-right" type="button" value="'+lb+'" onclick="'+moduleName+'.'+cb+'(\''+di+'\');"></input>'+
			'</div>';
		return html;
	}

	// Add a standard input for a plug-in variable.
	function htmlAddInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var typ = (vr.toLowerCase() == 'password') ? 'type="password"' : 'type="text"';
		var html = '<div class="clearfix labelInputContainer">'+
					'<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>'+
					'<div class="pull-left">'+
						'<input class="customInput altui-ui-input form-control" '+typ+' size="'+si+'" id="'+moduleName+vr+di+'" value="'+val+'" onChange="'+moduleName+'.updateVariable(\''+vr+'\',this.value)">'+
					'</div>'+
				   '</div>';
		if (vr.toLowerCase() == 'password') {
			html += '<div class="clearfix labelInputContainer">'+
					'<div class="pull-left inputLabel" style="width:280px;">&nbsp; </div>'+
					'<div class="pull-left">'+
						'<input class="customCheckbox" type="checkbox" id="'+moduleName+vr+di+'Checkbox">'+
						'<label class="labelForCustomCheckbox" for="'+moduleName+vr+di+'Checkbox">Show Password</label>'+
					'</div>'+
				   '</div>';
			html += '<script type="text/javascript">'+
					'$("#'+moduleName+vr+di+'Checkbox").on("change", function() {'+
					' var typ = (this.checked) ? "text" : "password" ; '+
					' $("#'+moduleName+vr+di+'").prop("type", typ);'+
					'});'+
					'</script>';
		}
		return html;
	}

	// Add a label and pulldown selection
	function htmlAddPulldown(di, lb, vr, values) {
		try {
			var selVal = '';
			if (vr.startsWith('PI')) {
				var ps = varGet(di,'PollSettings');
				var pa = ps.split(',');
				selVal = pa[Number(vr.charAt(2))];
			} else {
				selVal = varGet(di, vr);
			}
			var html = '<div class="clearfix labelInputContainer">'+
				'<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>'+
				'<div class="pull-left customSelectBoxContainer">'+
				'<select id="'+moduleName+vr+di+'" onChange="'+moduleName+'.updateVariable(\''+vr+'\',this.value)" class="customSelectBox form-control">';
			for(var i=0;i<values.length;i++){
				html += '<option value="'+values[i].value+'" '+((values[i].value==selVal)?'selected':'')+'>'+values[i].label+'</option>';
			}
			html += '</select>'+
				'</div>'+
				'</div>';
			return html;
		} catch (e) {
			Utils.logError(moduleName+': htmlAddPulldown(): ' + e);
		}
	}

	// Update variable in user_data and lu_status
	function varSet(deviceID, varID, varVal, sid) {
		if (typeof(sid) == 'undefined') { sid = MOD_SID; }
		api.setDeviceStateVariablePersistent(deviceID, sid, varID, varVal);
	}
	// Get variable value. When variable is not defined, this new api returns false not null.
	function varGet(deviceID, varID, sid) {
		try {
			if (typeof(sid) == 'undefined') { sid = MOD_SID; }
			var res = api.getDeviceState(deviceID, sid, varID);
			if (res !== false && res !== null && res !== 'null' && typeof(res) !== 'undefined') {
				return res;
			} else {
				return '';
			}	
        } catch (e) {
            return '';
        }
	}

	// Expose interface functions
    myModule = {
        init: _init,
        onBeforeCpanelClose: _onBeforeCpanelClose,
		showSettings: _showSettings,
		showStatus: _showStatus,
		updateVariable : _updateVariable
    };
    return myModule;
})(api);

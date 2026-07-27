'use strict';
'require view';
'require dom';
'require fs';
'require rpc';
'require mt5700m.controls as controls';

var callManagerStatus = rpc.declare({ object: 'mt5700m', method: 'status', expect: { } });
var callTraffic = rpc.declare({ object: 'mt5700m-traffic', method: 'summary', expect: { } });

function parseKeyValues(output) {
	var data = {};
	String(output || '').trim().split(/\n/).forEach(function(line) {
		var pos = line.indexOf('=');
		if (pos > -1)
			data[line.substring(0, pos)] = line.substring(pos + 1);
	});
	return data;
}

function trafficTotal(item) {
	return (Number(item && item.rx) || 0) + (Number(item && item.tx) || 0);
}

function trafficDateKey(item, monthly) {
	var date = item && item.date || {};
	var month = String(date.month || 0).padStart(2, '0');
	var day = String(date.day || 0).padStart(2, '0');
	return monthly ? [ date.year || 0, month ].join('-') : [ date.year || 0, month, day ].join('-');
}

function sortedTraffic(items, monthly) {
	return (items || []).slice().sort(function(a, b) { return trafficDateKey(a, monthly).localeCompare(trafficDateKey(b, monthly)); });
}

function currentTraffic(items, monthly) {
	var now = new Date();
	var key = monthly
		? [ now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0') ].join('-')
		: [ now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0'), String(now.getDate()).padStart(2, '0') ].join('-');
	return (items || []).filter(function(item) { return trafficDateKey(item, monthly) === key; })[0] || {};
}

function trafficUpdated(iface) {
	var value = iface && iface.updated;
	if (!value || !value.date || value.date.year < 2024)
		return _('Waiting for data');
	return '%04d-%02d-%02d %02d:%02d'.format(value.date.year || 0, value.date.month || 0,
		value.date.day || 0, value.time && value.time.hour || 0, value.time && value.time.minute || 0);
}

function aggregateTraffic(interfaces) {
	var totals = { rx:0, tx:0 }, days = {}, months = {}, updated = null, updatedKey = '';

	(interfaces || []).forEach(function(iface) {
		var traffic = iface && iface.traffic || {}, value = iface && iface.updated || {};
		var key = value.date
			? '%04d%02d%02d%02d%02d'.format(value.date.year || 0, value.date.month || 0,
				value.date.day || 0, value.time && value.time.hour || 0, value.time && value.time.minute || 0)
			: '';
		if (key > updatedKey) {
			updated = value;
			updatedKey = key;
		}
		totals.rx += Number(traffic.total && traffic.total.rx) || 0;
		totals.tx += Number(traffic.total && traffic.total.tx) || 0;
		(traffic.day || []).forEach(function(item) {
			var dayKey = trafficDateKey(item, false);
			days[dayKey] = days[dayKey] || { date:item.date, rx:0, tx:0 };
			days[dayKey].rx += Number(item.rx) || 0;
			days[dayKey].tx += Number(item.tx) || 0;
		});
		(traffic.month || []).forEach(function(item) {
			var monthKey = trafficDateKey(item, true);
			months[monthKey] = months[monthKey] || { date:item.date, rx:0, tx:0 };
			months[monthKey].rx += Number(item.rx) || 0;
			months[monthKey].tx += Number(item.tx) || 0;
		});
	});

	return {
		updated:updated,
		traffic:{
			total:totals,
			day:Object.keys(days).map(function(key) { return days[key]; }),
			month:Object.keys(months).map(function(key) { return months[key]; })
		}
	};
}

return view.extend({
	load: function() {
		return callManagerStatus().catch(function() { return {}; }).then(function(manager) {
			return Promise.all([
				fs.exec('/usr/sbin/mt5700m-at', [ 'status' ]).catch(function(err) { return { stdout:'', stderr:err.message || String(err) }; }),
				fs.exec('/usr/sbin/mt5700m-at', [ 'advanced', 'session' ]).catch(function(err) { return { stdout:'', stderr:err.message || String(err) }; }),
				callTraffic().catch(function() { return { interfaces:[] }; })
			]).then(function(results) {
				return { native:results[0], session:results[1], traffic:results[2], manager:manager };
			});
		});
	},

	parseStatus: function(res) {
		var data = parseKeyValues(res.native && res.native.stdout || '');

		data.reachable = data.connected === '1' ? '1' : '0';
		data.model = data.product_name || 'MT5700M';
		data.temperature = String(data.temperature || '').replace(/[^0-9.-]/g, '');
		data.sysmode_detail = data.network_mode || data.sysmode_detail || data.sysmode || '';
		data.at_port = data.at_port || res.manager.at_port || '';
		data.connected = res.manager.connected === true && data.reachable === '1' && !/^(|NOSERVICE|NO SERVICE|UNKNOWN)$/i.test(data.sysmode || data.sysmode_detail || '') ? '1' : '0';
		if (/^(upgrade|dump|unknown)$/.test(data.usb_state || '')) {
			data.reachable = '0';
			data.connected = '0';
		}
		data.network_interface = res.manager.network || '';
		data.error = res.native && res.native.stderr || '';
		return data;
	},

	styleNode: function() {
		return E('style', {}, [
			'.mt5700m-page{max-width:1120px;margin:0 auto;color:var(--text-color-high,#20242a)}',
			'.mt5700m-hero{position:relative;overflow:hidden;display:flex;justify-content:space-between;align-items:center;gap:20px;padding:22px 24px;margin-bottom:14px;border-radius:16px;background:linear-gradient(135deg,#1264d8 0%,#087eae 58%,#07988e 100%);color:#fff;box-shadow:0 10px 28px rgba(14,92,155,.16)}',
			'.mt5700m-hero:after{content:"";position:absolute;width:210px;height:210px;right:-78px;top:-118px;border:42px solid rgba(255,255,255,.08);border-radius:50%}.mt5700m-hero-copy,.mt5700m-hero-side{position:relative;z-index:1}',
			'.mt5700m-title{margin:0 0 6px;color:#fff;font-size:27px;line-height:1.2}.mt5700m-summary{font-size:13px;line-height:1.5;color:rgba(255,255,255,.84)}',
			'.mt5700m-hero-meta{display:flex;flex-wrap:wrap;gap:7px 18px;margin-top:13px;font-size:11px;color:rgba(255,255,255,.72)}.mt5700m-hero-meta strong{margin-left:5px;color:#fff;font-weight:700}',
			'.mt5700m-hero-side{display:flex;flex-direction:column;align-items:flex-end;gap:10px}.mt5700m-status{display:inline-flex;align-items:center;gap:8px;padding:8px 12px;border-radius:999px;background:rgba(255,255,255,.16);font-size:12px;font-weight:700;white-space:nowrap}.mt5700m-dot{width:8px;height:8px;border-radius:50%;background:#ffcd57;box-shadow:0 0 0 4px rgba(255,205,87,.18)}.mt5700m-status.online .mt5700m-dot{background:#78f2b0;box-shadow:0 0 0 4px rgba(120,242,176,.18)}.mt5700m-refresh{border-color:rgba(255,255,255,.30)!important;background:rgba(255,255,255,.10)!important;color:#fff!important}',
			'.mt5700m-focus-grid{display:grid;grid-template-columns:1.12fr .88fr 1.18fr;gap:12px;margin-bottom:12px}.mt5700m-focus{display:flex;flex-direction:column;min-height:230px;padding:17px 18px}.mt5700m-focus-head{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;margin-bottom:13px}.mt5700m-focus-title{font-size:14px;font-weight:750}.mt5700m-focus-desc{margin-top:3px;color:var(--mt-ui-muted);font-size:10px;line-height:1.4}',
			'.mt5700m-badge{display:inline-flex;align-items:center;gap:5px;padding:4px 8px;border-radius:999px;background:#eef2f6;color:#6b7480;font-size:10px;font-weight:750;white-space:nowrap}.mt5700m-badge:before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}.mt5700m-badge.good,.mt5700m-badge.active{background:#e8f8f1;color:#087c60}.mt5700m-badge.fair{background:#fff5df;color:#9b6500}.mt5700m-badge.weak{background:#fff0ee;color:#b84035}',
			'.mt5700m-radio-refresh{margin:-2px 0 11px;padding:0 0 10px;border-bottom:1px solid var(--mt-ui-border)}.mt5700m-radio-refresh-row{display:flex;align-items:center;gap:7px;overflow-x:auto;padding-bottom:2px;white-space:nowrap}.mt5700m-radio-refresh .btn{box-sizing:border-box;min-height:29px;padding:4px 9px;font-size:10px}.mt5700m-auto-toggle.active{border-color:#168b72!important;background:#e8f8f1!important;color:#087c60!important}.mt5700m-refresh-interval{display:inline-flex;align-items:center;gap:5px;height:29px;padding:4px 9px!important;font-size:10px;font-weight:inherit;white-space:nowrap}.mt5700m-refresh-interval input{box-sizing:border-box;width:45px;height:19px;padding:1px 3px;border:0!important;outline:0!important;background:transparent!important;box-shadow:none!important;color:inherit!important;caret-color:currentColor;text-align:center;-moz-appearance:textfield}.mt5700m-refresh-interval input::-webkit-inner-spin-button,.mt5700m-refresh-interval input::-webkit-outer-spin-button{margin:0;-webkit-appearance:none}.mt5700m-radio-refresh-state{display:block;min-height:13px;margin-top:6px;color:var(--mt-ui-muted);font-size:9px;line-height:1.35}.mt5700m-radio-refresh-state.error{color:#b84035}',
			'.mt5700m-signal-value{display:flex;align-items:baseline;gap:6px}.mt5700m-signal-value strong{font-size:31px;letter-spacing:-.04em}.mt5700m-signal-value span{font-size:11px;color:var(--mt-ui-muted)}.mt5700m-signal-bars{display:flex;align-items:flex-end;gap:3px;height:52px;margin:5px 0 13px}.mt5700m-signal-bar{flex:1;min-width:2px;border-radius:2px 2px 1px 1px;background:var(--mt-ui-border);opacity:.55}.mt5700m-signal-bar.on{background:#4b94df;opacity:1}.mt5700m-signal-bars.excellent .on{background:#13a979}.mt5700m-signal-bars.fair .on{background:#e4a23a}.mt5700m-signal-bars.weak .on{background:#db5b52}',
			'.mt5700m-signal-meta{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px;margin-top:auto}.mt5700m-mini{padding:8px;border-radius:9px;background:var(--background-color-low,#f5f7f9)}.mt5700m-mini span{display:block;margin-bottom:3px;color:var(--mt-ui-muted);font-size:9px}.mt5700m-mini strong{font-size:12px}',
			'.mt5700m-carrier-main{margin:2px 0 12px}.mt5700m-carrier-main strong{display:block;font-size:29px;line-height:1.15;letter-spacing:-.03em}.mt5700m-carrier-main span{display:block;margin-top:4px;color:var(--mt-ui-muted);font-size:11px}.mt5700m-band-list{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}.mt5700m-band{padding:5px 8px;border-radius:8px;background:#edf5ff;color:#176bc1;font-size:10px;font-weight:700}.mt5700m-carrier-stats{display:grid;grid-template-columns:1fr 1fr;gap:7px;margin-top:auto}',
			'.mt5700m-ip-list{display:grid;gap:9px}.mt5700m-ip-row{padding:10px 11px;border-radius:10px;background:var(--background-color-low,#f5f7f9)}.mt5700m-ip-head{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:5px;font-size:10px;color:var(--mt-ui-muted)}.mt5700m-ip-state{font-weight:700;color:#9a6200}.mt5700m-ip-state.on{color:#087c60}.mt5700m-ip-value{font:600 12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}.mt5700m-ip-meta{display:flex;justify-content:space-between;gap:10px;margin-top:9px;color:var(--mt-ui-muted);font-size:10px}',
			'.mt5700m-card-link{display:inline-flex;align-items:center;gap:5px;margin-top:auto;padding-top:12px;color:#176bc1;font-size:10px;font-weight:700;text-decoration:none}.mt5700m-card-link:after{content:"›";font-size:16px;line-height:10px}',
			'.mt5700m-traffic{padding:18px;margin-bottom:12px}.mt5700m-traffic-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:14px}.mt5700m-traffic-head h3{margin:0 0 4px;font-size:16px}.mt5700m-traffic-head p{margin:0;color:var(--mt-ui-muted);font-size:10px}.mt5700m-traffic-side{text-align:right}.mt5700m-updated{color:var(--mt-ui-muted);font-size:10px;white-space:nowrap}.mt5700m-legend{display:flex;justify-content:flex-end;gap:10px;margin-top:5px;color:var(--mt-ui-muted);font-size:9px}.mt5700m-legend span:before{content:"";display:inline-block;width:7px;height:3px;margin-right:4px;border-radius:9px;background:#337de8;vertical-align:middle}.mt5700m-legend span:last-child:before{background:#16a085}',
			'.mt5700m-traffic-layout{display:grid;grid-template-columns:repeat(3,minmax(0,.62fr)) minmax(300px,1.8fr);gap:10px}.mt5700m-traffic-stat{padding:13px;border-radius:11px;background:var(--background-color-low,#f5f7f9)}.mt5700m-traffic-label{font-size:10px;color:var(--mt-ui-muted);margin-bottom:6px}.mt5700m-traffic-value{font-size:18px;font-weight:750;letter-spacing:-.02em}.mt5700m-traffic-split{margin-top:5px;color:var(--mt-ui-muted);font-size:9px;line-height:1.45}',
			'.mt5700m-days{display:flex;flex-direction:column;justify-content:center;gap:6px;padding:2px 0 2px 8px}.mt5700m-day{display:grid;grid-template-columns:42px minmax(80px,1fr) 112px;align-items:center;gap:8px;font-size:9px}.mt5700m-date{color:var(--mt-ui-muted);font-weight:650}.mt5700m-bars{display:flex;flex-direction:column;gap:2px}.mt5700m-bar{height:4px;border-radius:999px;background:var(--background-color-low,#eef1f5);overflow:hidden}.mt5700m-bar i{display:block;height:100%;min-width:2px;border-radius:inherit;background:#337de8}.mt5700m-bar.tx i{background:#16a085}.mt5700m-values{text-align:right;font-variant-numeric:tabular-nums;color:var(--mt-ui-muted)}',
			'.mt5700m-shortcuts{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}.mt5700m-shortcut{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:14px 16px;color:inherit;text-decoration:none}.mt5700m-shortcut strong{display:block;font-size:12px}.mt5700m-shortcut span{display:block;margin-top:3px;color:var(--mt-ui-muted);font-size:9px;line-height:1.4}.mt5700m-shortcut b{color:#176bc1;font-size:20px}.mt5700m-alert{margin-bottom:12px}',
			'@media(max-width:900px){.mt5700m-focus-grid{grid-template-columns:1fr 1fr}.mt5700m-address-card{grid-column:1/-1;min-height:auto}.mt5700m-traffic-layout{grid-template-columns:repeat(3,1fr)}.mt5700m-days{grid-column:1/-1;padding:8px 0 0}}',
			'@media(max-width:650px){.mt5700m-hero{display:block}.mt5700m-hero-side{align-items:flex-start;margin-top:14px}.mt5700m-focus-grid,.mt5700m-shortcuts{grid-template-columns:1fr}.mt5700m-address-card{grid-column:auto}.mt5700m-focus{min-height:auto}.mt5700m-radio-refresh-row{gap:5px}.mt5700m-radio-refresh .btn{padding-left:7px;padding-right:7px}.mt5700m-traffic-layout{grid-template-columns:1fr}.mt5700m-days{grid-column:auto}.mt5700m-day{grid-template-columns:38px 1fr}.mt5700m-values{grid-column:2;text-align:left}.mt5700m-traffic-head{display:block}.mt5700m-updated{margin-top:7px}}'
		].join(''));
	},

	signalQuality: function(kind, value) {
		var percentage, levels, index;
		if (isNaN(value))
			return { label:_('No data'), cls:'unknown', percentage:0 };
		if (kind === 'rsrp') { percentage = (value + 120) * 2.5; levels = [ -80, -90, -100 ]; }
		else if (kind === 'rsrq') { percentage = (value + 25) * 4; levels = [ -10, -15, -20 ]; }
		else { percentage = (value + 10) * 2.5; levels = [ 20, 13, 0 ]; }
		index = value >= levels[0] ? 0 : value >= levels[1] ? 1 : value >= levels[2] ? 2 : 3;
		return {
			label:[ _('Excellent'), _('Good'), _('Fair'), _('Weak') ][index],
			cls:[ 'excellent', 'good', 'fair', 'weak' ][index],
			percentage:Math.max(0, Math.min(100, percentage))
		};
	},

	carrierInfo: function(data) {
		var count = parseInt(data.carrier_count || '0', 10) || 0;
		var carriers = [], parts, i;
		for (i = 1; i <= count; i++) {
			parts = String(data['carrier_' + i] || '').split('|');
			if (parts.length < 8) continue;
			carriers.push({ radio:parts[0], band:parts[1], dlBandwidth:parts[4], ulBandwidth:parts[7] });
		}
		return {
			available:carriers.length > 0,
			active:data.ca_active === '1' && carriers.length > 1,
			dual:data.dc_active === '1', mode:data.ca_mode || '', count:carriers.length,
			dlBandwidth:data.ca_dl_bandwidth || '', ulBandwidth:data.ca_ul_bandwidth || '', carriers:carriers
		};
	},

	updateSignalCard: function(data, refs) {
		var rsrp = parseFloat(data.rsrp), rsrq = parseFloat(data.rsrq), sinr = parseFloat(data.sinr);
		var quality = this.signalQuality('rsrp', rsrp), active = isNaN(rsrp) ? 0 : Math.max(1, Math.round(quality.percentage / 100 * 14));
		var bars = [], i;
		for (i = 0; i < 14; i++)
			bars.push(E('span', { 'class':'mt5700m-signal-bar' + (i < active ? ' on' : ''), 'style':'height:%dpx'.format(8 + i * 3) }));

		refs.badge.className = 'mt5700m-badge ' + quality.cls;
		dom.content(refs.badge, quality.label);
		dom.content(refs.rsrp, isNaN(rsrp) ? '--' : String(data.rsrp));
		refs.bars.className = 'mt5700m-signal-bars ' + quality.cls;
		dom.content(refs.bars, bars);
		dom.content(refs.rsrq, isNaN(rsrq) ? '--' : data.rsrq + ' dB');
		dom.content(refs.sinr, isNaN(sinr) ? '--' : data.sinr + ' dB');
	},

	refreshInterval: function(state) {
		var seconds = parseFloat(state.intervalInput.value);
		if (!isFinite(seconds) || seconds <= 0) {
			seconds = 5;
			state.intervalInput.value = '5';
		}
		return seconds * 1000;
	},

	scheduleRadioRefresh: function(state) {
		var self = this;
		var due;
		if (state.timer !== null) {
			window.clearTimeout(state.timer);
			state.timer = null;
		}
		if (!state.auto || state.destroyed || document.hidden)
			return;
		due = Date.now() + this.refreshInterval(state);
		(function armTimer() {
			var remaining;
			if (!state.auto || state.destroyed || document.hidden)
				return;
			remaining = due - Date.now();
			if (remaining <= 0) {
				state.timer = null;
				self.refreshRadioStatus(state);
				return;
			}
			// Browsers cap a single timer at a signed 32-bit millisecond value.
			// Re-arm very long user-defined intervals instead of wrapping them.
			state.timer = window.setTimeout(armTimer, Math.min(remaining, 2147483647));
		})();
	},

	stopRadioRefresh: function(state) {
		if (!state || state.destroyed)
			return;
		state.destroyed = true;
		if (state.timer !== null)
			window.clearTimeout(state.timer);
		state.timer = null;
		if (state.visibilityHandler)
			document.removeEventListener('visibilitychange', state.visibilityHandler);
		if (state.pageHideHandler)
			window.removeEventListener('pagehide', state.pageHideHandler);
	},

	refreshRadioStatus: function(state) {
		var self = this;
		if (state.busy || state.destroyed)
			return Promise.resolve();

		if (state.timer !== null) {
			window.clearTimeout(state.timer);
			state.timer = null;
		}
		state.busy = true;
		state.refreshButton.disabled = true;
		dom.content(state.refreshButton, _('Refreshing…'));
		state.message.className = 'mt5700m-radio-refresh-state';
		state.message.title = '';
		dom.content(state.message, _('Refreshing signal and carrier status…'));

		return fs.exec('/usr/sbin/mt5700m-at', [ 'radio-status' ]).then(function(result) {
			var fresh = parseKeyValues(result.stdout || '');
			var signalKeys = [ 'sysmode', 'rsrp', 'rsrq', 'sinr', 'rssi', 'rscp', 'ecio' ];
			var carrierKeys = [
				'carrier_count', 'ca_active', 'dc_active', 'nr_carrier_count',
				'lte_carrier_count', 'lte_secondary_count', 'secondary_connection_count',
				'ca_mode', 'ca_dl_bandwidth', 'ca_ul_bandwidth'
			];
			var hasSignal = signalKeys.some(function(key) {
				return Object.prototype.hasOwnProperty.call(fresh, key);
			});
			var hasCarrier = Object.prototype.hasOwnProperty.call(fresh, 'carrier_count');

			if (!hasSignal && !hasCarrier)
				throw new Error(_('The modem returned no signal or carrier data.'));

			if (hasSignal)
				signalKeys.forEach(function(key) { delete state.data[key]; });
			if (hasCarrier) {
				Object.keys(state.data).forEach(function(key) {
					if (/^carrier_[0-9]+$/.test(key))
						delete state.data[key];
				});
				carrierKeys.forEach(function(key) { delete state.data[key]; });
			}
			Object.keys(fresh).forEach(function(key) { state.data[key] = fresh[key]; });

			if (hasSignal)
				self.updateSignalCard(state.data, state.signalRefs);
			if (hasCarrier)
				self.updateCarrierCard(self.carrierInfo(state.data), state.carrierRefs);
		}).then(function() {
			if (state.destroyed)
				return;
			state.message.className = 'mt5700m-radio-refresh-state';
			state.message.title = '';
			dom.content(state.message, _('Updated at %s').format(new Date().toLocaleTimeString()));
		}, function(err) {
			if (state.destroyed)
				return;
			state.message.className = 'mt5700m-radio-refresh-state error';
			state.message.title = err && err.message || String(err);
			dom.content(state.message, _('Refresh failed; the previous values are retained.'));
		}).then(function() {
			state.busy = false;
			if (!state.destroyed) {
				state.refreshButton.disabled = false;
				dom.content(state.refreshButton, _('Refresh signal and carriers'));
				self.scheduleRadioRefresh(state);
			}
		});
	},

	radioRefreshControls: function(state) {
		var self = this;
		state.refreshButton = E('button', {
			'type':'button',
			'class':'btn cbi-button-action',
			'click':function() { self.refreshRadioStatus(state); }
		}, _('Refresh signal and carriers'));
		state.autoButton = E('button', {
			'type':'button',
			'class':'btn mt5700m-auto-toggle',
			'aria-pressed':'false',
			'click':function() {
				state.auto = !state.auto;
				state.autoButton.className = 'btn mt5700m-auto-toggle' + (state.auto ? ' active' : '');
				state.autoButton.setAttribute('aria-pressed', state.auto ? 'true' : 'false');
				dom.content(state.autoButton, state.auto ? _('Auto refresh: On') : _('Auto refresh: Off'));
				self.scheduleRadioRefresh(state);
			}
		}, _('Auto refresh: Off'));
		state.intervalInput = E('input', {
			'type':'number',
			'step':'any',
			'value':'5',
			'inputmode':'decimal',
			'aria-label':_('Refresh interval in seconds'),
			'change':function() {
				self.refreshInterval(state);
				self.scheduleRadioRefresh(state);
			}
		});
		state.message = E('span', { 'class':'mt5700m-radio-refresh-state' }, _('Only signal and carrier status are refreshed.'));
		state.visibilityHandler = function() {
			if (document.hidden && state.timer !== null) {
				window.clearTimeout(state.timer);
				state.timer = null;
			}
			else if (!document.hidden) {
				self.scheduleRadioRefresh(state);
			}
		};
		state.pageHideHandler = function() { self.stopRadioRefresh(state); };
		document.addEventListener('visibilitychange', state.visibilityHandler);
		window.addEventListener('pagehide', state.pageHideHandler);

		return E('div', { 'class':'mt5700m-radio-refresh' }, [
			E('div', { 'class':'mt5700m-radio-refresh-row' }, [
				state.refreshButton,
				state.autoButton,
				E('label', { 'class':'btn mt5700m-refresh-interval' }, [
					_('Interval'), state.intervalInput, _('seconds')
				])
			]),
			state.message
		]);
	},

	signalCard: function(data, refs, refreshControls) {
		refs.badge = E('span', { 'class':'mt5700m-badge' });
		refs.rsrp = E('strong');
		refs.bars = E('div', { 'class':'mt5700m-signal-bars', 'aria-hidden':'true' });
		refs.rsrq = E('strong');
		refs.sinr = E('strong');
		var card = E('section', { 'class':'mt5700m-focus mt-ui-card' }, [
			E('div', { 'class':'mt5700m-focus-head' }, [
				E('div', {}, [ E('div', { 'class':'mt5700m-focus-title' }, _('Signal')), E('div', { 'class':'mt5700m-focus-desc' }, _('Current radio quality at a glance')) ]),
				refs.badge
			]),
			refreshControls,
			E('div', { 'class':'mt5700m-signal-value' }, [ refs.rsrp, E('span', {}, 'RSRP · dBm') ]),
			refs.bars,
			E('div', { 'class':'mt5700m-signal-meta' }, [
				E('div', { 'class':'mt5700m-mini' }, [ E('span', {}, 'RSRQ'), refs.rsrq ]),
				E('div', { 'class':'mt5700m-mini' }, [ E('span', {}, 'SINR'), refs.sinr ]),
				E('div', { 'class':'mt5700m-mini' }, [ E('span', {}, _('Temperature')), E('strong', {}, data.temperature ? data.temperature + '°C' : '--') ])
			])
		]);
		this.updateSignalCard(data, refs);
		return card;
	},

	updateCarrierCard: function(info, refs) {
		var active = info.active || info.dual;
		var badge = !info.available ? _('Unavailable') : info.active ? _('Aggregating') : info.dual ? _('Dual connectivity') : _('Single carrier');
		var headline = !info.available ? '--' : info.active ? info.count + 'CA' : info.dual ? (info.mode || 'EN-DC') : (info.carriers[0] ? info.carriers[0].band : _('Single carrier'));
		refs.badge.className = 'mt5700m-badge' + (active ? ' active' : '');
		dom.content(refs.badge, badge);
		dom.content(refs.headline, headline);
		dom.content(refs.mode, info.mode || _('Mobile network'));
		dom.content(refs.bands, info.carriers.length ? info.carriers.map(function(item) {
			return E('span', { 'class':'mt5700m-band' }, item.radio + ' · ' + item.band);
		}) : E('span', { 'class':'mt5700m-focus-desc' }, _('Current carrier information is unavailable.')));
		dom.content(refs.downlink, info.dlBandwidth ? info.dlBandwidth + ' MHz' : '--');
		dom.content(refs.uplink, info.ulBandwidth ? info.ulBandwidth + ' MHz' : '--');
	},

	carrierCard: function(info, refs) {
		refs.badge = E('span', { 'class':'mt5700m-badge' });
		refs.headline = E('strong');
		refs.mode = E('span');
		refs.bands = E('div', { 'class':'mt5700m-band-list' });
		refs.downlink = E('strong');
		refs.uplink = E('strong');
		var card = E('section', { 'class':'mt5700m-focus mt-ui-card' }, [
			E('div', { 'class':'mt5700m-focus-head' }, [
				E('div', {}, [ E('div', { 'class':'mt5700m-focus-title' }, _('Carrier status')), E('div', { 'class':'mt5700m-focus-desc' }, _('Carrier aggregation and bandwidth')) ]),
				refs.badge
			]),
			E('div', { 'class':'mt5700m-carrier-main' }, [ refs.headline, refs.mode ]),
			refs.bands,
			E('div', { 'class':'mt5700m-carrier-stats' }, [
				E('div', { 'class':'mt5700m-mini' }, [ E('span', {}, _('Downlink bandwidth')), refs.downlink ]),
				E('div', { 'class':'mt5700m-mini' }, [ E('span', {}, _('Uplink bandwidth')), refs.uplink ])
			]),
			E('a', { 'class':'mt5700m-card-link', 'href':L.url('admin/modem/mt5700m/network') }, _('View radio and cell details'))
		]);
		this.updateCarrierCard(info, refs);
		return card;
	},

	addressCard: function(session) {
		var active = session.ipv4Connected || session.ipv6Connected;
		return E('section', { 'class':'mt5700m-focus mt5700m-address-card mt-ui-card' }, [
			E('div', { 'class':'mt5700m-focus-head' }, [
				E('div', {}, [ E('div', { 'class':'mt5700m-focus-title' }, _('Mobile IP')), E('div', { 'class':'mt5700m-focus-desc' }, _('Addresses assigned by the mobile network')) ]),
				E('span', { 'class':'mt5700m-badge' + (active ? ' active' : '') }, active ? _('Active') : _('Disconnected'))
			]),
			E('div', { 'class':'mt5700m-ip-list' }, [
				E('div', { 'class':'mt5700m-ip-row' }, [ E('div', { 'class':'mt5700m-ip-head' }, [ E('span', {}, 'IPv4'), E('span', { 'class':'mt5700m-ip-state' + (session.ipv4Connected ? ' on' : '') }, session.ipv4Connected ? _('Connected') : _('Not assigned')) ]), E('div', { 'class':'mt5700m-ip-value' }, session.ipv4Address || '--') ]),
				E('div', { 'class':'mt5700m-ip-row' }, [ E('div', { 'class':'mt5700m-ip-head' }, [ E('span', {}, 'IPv6'), E('span', { 'class':'mt5700m-ip-state' + (session.ipv6Connected ? ' on' : '') }, session.ipv6Connected ? _('Connected') : _('Not assigned')) ]), E('div', { 'class':'mt5700m-ip-value' }, session.ipv6Address || '--') ])
			]),
			E('div', { 'class':'mt5700m-ip-meta' }, [ E('span', {}, session.capability || '--'), E('span', {}, 'MTU ' + (session.mtu || '--')) ]),
			E('a', { 'class':'mt5700m-card-link', 'href':L.url('admin/modem/mt5700m/connection') }, _('View connection details'))
		]);
	},

	trafficPanel: function(report, interfaceName) {
		var interfaces = report.interfaces || [];
		var iface = interfaces.length > 1 ? aggregateTraffic(interfaces) :
			interfaces.filter(function(item) { return item.name === interfaceName; })[0] ||
			interfaces[0] || { traffic:{} };
		var traffic = iface.traffic || {}, days = sortedTraffic(traffic.day, false), months = sortedTraffic(traffic.month, true);
		var today = currentTraffic(days, false), month = currentTraffic(months, true), lifetime = traffic.total || {};
		var recentDays = days.slice(-7).reverse(), maximum = Math.max.apply(Math, recentDays.map(trafficTotal).concat([ 1 ]));
		var dayRows = recentDays.length ? recentDays.map(function(item) {
			var rx = Number(item.rx) || 0, tx = Number(item.tx) || 0;
			return E('div', { 'class':'mt5700m-day' }, [
				E('span', { 'class':'mt5700m-date' }, trafficDateKey(item, false).substring(5)),
				E('div', { 'class':'mt5700m-bars' }, [ E('div', { 'class':'mt5700m-bar' }, E('i', { 'style':'width:' + Math.max(1, rx / maximum * 100).toFixed(1) + '%' })), E('div', { 'class':'mt5700m-bar tx' }, E('i', { 'style':'width:' + Math.max(1, tx / maximum * 100).toFixed(1) + '%' })) ]),
				E('span', { 'class':'mt5700m-values' }, controls.formatBytes(trafficTotal(item)))
			]);
		}) : [ E('div', { 'class':'mt5700m-focus-desc' }, _('Statistics appear after the MT5700M data interface has carried traffic for a few minutes.')) ];
		function stat(label, item) {
			return E('div', { 'class':'mt5700m-traffic-stat' }, [ E('div', { 'class':'mt5700m-traffic-label' }, label), E('div', { 'class':'mt5700m-traffic-value' }, controls.formatBytes(trafficTotal(item))), E('div', { 'class':'mt5700m-traffic-split' }, _('Download %s · Upload %s').format(controls.formatBytes(item.rx), controls.formatBytes(item.tx))) ]);
		}
		return E('section', { 'class':'mt5700m-traffic mt-ui-card' }, [
			E('div', { 'class':'mt5700m-traffic-head' }, [ E('div', {}, [ E('h3', {}, _('Traffic Statistics')), E('p', {}, _('Local usage recorded only for the MT5700M data interface')) ]), E('div', { 'class':'mt5700m-traffic-side' }, [ E('div', { 'class':'mt5700m-updated' }, _('Last updated') + ' · ' + trafficUpdated(iface)), E('div', { 'class':'mt5700m-legend' }, [ E('span', {}, _('Download')), E('span', {}, _('Upload')) ]) ]) ]),
			E('div', { 'class':'mt5700m-traffic-layout' }, [ stat(_('Today'), today), stat(_('This month'), month), stat(_('All-time total'), lifetime), E('div', { 'class':'mt5700m-days' }, dayRows) ])
		]);
	},

	shortcut: function(title, description, path) {
		return E('a', { 'class':'mt5700m-shortcut mt-ui-card', 'href':L.url(path) }, [ E('div', {}, [ E('strong', {}, title), E('span', {}, description) ]), E('b', {}, '›') ]);
	},

	render: function(res) {
		var data = this.parseStatus(res), session = controls.parseSession(res.session && res.session.stdout || '');
		var reachable = data.reachable === '1', connected = data.connected === '1', carrierInfo = this.carrierInfo(data);
		var operator = data.operator || '';
		if (this.radioRefreshState)
			this.stopRadioRefresh(this.radioRefreshState);
		var radioState = {
			data:data,
			signalRefs:{},
			carrierRefs:{},
			auto:false,
			busy:false,
			destroyed:false,
			timer:null
		};
		this.radioRefreshState = radioState;
		var refreshControls = this.radioRefreshControls(radioState);
		if (!/[A-Za-z0-9\u4e00-\u9fff]/.test(operator)) operator = '';
		var usbNames = { upgrade:_('Upgrade mode'), dump:_('Dump mode'), unknown:_('Unknown USB mode') };
		var abnormalUsb = data.usb_state === 'upgrade' || data.usb_state === 'dump' || data.usb_state === 'unknown';
		return E('div', { 'class':'mt5700m-page mt-ui-page' }, [
			this.styleNode(), controls.styleNode(),
			data.error ? E('div', { 'class':'alert-message warning mt5700m-alert' }, data.error) : null,
			res.session && res.session.stderr ? E('div', { 'class':'alert-message warning mt5700m-alert' }, res.session.stderr) : null,
			abnormalUsb ? E('div', { 'class':'alert-message warning mt5700m-alert' }, _('The MT5700M is in %s. Mobile data and AT management are unavailable until normal mode returns.').format(usbNames[data.usb_state])) : null,
			E('section', { 'class':'mt5700m-hero' }, [
				E('div', { 'class':'mt5700m-hero-copy' }, [
					E('h2', { 'class':'mt5700m-title' }, _('MT5700M Module')),
					E('div', { 'class':'mt5700m-summary' }, !reachable ? _('The modem did not respond. Check the module connection.') : connected ? _('Mobile network is connected and ready.') : _('The module is online, but mobile data is not connected.')),
					E('div', { 'class':'mt5700m-hero-meta' }, [ E('span', {}, [ _('Operator'), E('strong', {}, operator || '--') ]), E('span', {}, [ _('Network Mode'), E('strong', {}, data.sysmode_detail || data.sysmode || '--') ]), E('span', {}, [ _('Network interface'), E('strong', {}, data.network_interface || '--') ]) ])
				]),
				E('div', { 'class':'mt5700m-hero-side' }, [ E('div', { 'class':'mt5700m-status' + (connected ? ' online' : '') }, [ E('span', { 'class':'mt5700m-dot' }), connected ? _('Connected') : reachable ? _('Module online') : _('Unavailable') ]), E('button', { 'class':'btn mt5700m-refresh', 'click':function() { window.location.reload(); } }, _('Refresh')) ])
			]),
			E('div', { 'class':'mt5700m-focus-grid' }, [
				this.signalCard(data, radioState.signalRefs, refreshControls),
				this.carrierCard(carrierInfo, radioState.carrierRefs),
				this.addressCard(session)
			]),
			this.trafficPanel(res.traffic || {}, data.network_interface),
			E('div', { 'class':'mt5700m-shortcuts' }, [
				this.shortcut(_('Mobile data'), _('APN, dialing, IP details and session counters'), 'admin/modem/mt5700m/connection'),
				this.shortcut(_('Radio and Cells'), _('Bands, cells, radio policy and diagnostics'), 'admin/modem/mt5700m/network'),
				this.shortcut(_('Module and SIM'), _('Module identity, SIM information and maintenance'), 'admin/modem/mt5700m/system')
			])
		]);
	},

	remove: function() {
		this.stopRadioRefresh(this.radioRefreshState);
		this.radioRefreshState = null;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

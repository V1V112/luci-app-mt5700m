'use strict';
'require baseclass';

function modulation(index) {
	if (index === 255)
		return '';
	if (index <= 9)
		return 'QPSK';
	if (index <= 16)
		return '16QAM';
	if (index <= 28)
		return '64QAM';
	return '256QAM';
}

function quality(index) {
	if (index === 255)
		return 'unused';
	if (index <= 9)
		return 'weak';
	if (index <= 16)
		return 'fair';
	if (index <= 23)
		return 'good';
	return 'excellent';
}

function label(record) {
	if (!record || !record.value)
		return '--';
	return 'MCS ' + record.value + (record.modulation ? ' ' + record.modulation : '');
}

function parse(value) {
	var carriers = [];

	String(value || '').split('|').forEach(function(record) {
		var fields = record.split(',').map(function(field) { return field.trim(); });
		var rat, offset;

		if (fields.length < 5)
			return;

		rat = fields[1] === '1' ? 'NR' : fields[1] === '0' ? 'LTE' : 'UNKNOWN';
		for (offset = 2; offset + 2 < fields.length; offset += 3) {
			var tableIndex, code0, code1;

			if (!/^\d+$/.test(fields[offset]) || !/^\d+$/.test(fields[offset + 1]) || !/^\d+$/.test(fields[offset + 2]))
				continue;

			tableIndex = parseInt(fields[offset], 10);
			code0 = parseInt(fields[offset + 1], 10);
			code1 = parseInt(fields[offset + 2], 10);
			carriers.push({
				index:carriers.length + 1,
				rat:rat,
				mcsTableIndex:tableIndex,
				code0:code0,
				code1:code1,
				value:code0 === 255 ? '' : String(code0),
				modulation:modulation(code0),
				quality:quality(code0)
			});
		}
	});

	return carriers;
}

return baseclass.extend({
	parse:parse,
	modulation:modulation,
	quality:quality,
	label:label
});

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'htdocs', 'luci-static', 'resources', 'mt5700m', 'mcs.js'), 'utf8');
const mcs = new Function('baseclass', source)({ extend: value => value });

assert.deepStrictEqual(mcs.parse('0,1,1,19,0,0,0'), [ {
	index:1,
	rat:'NR',
	mcsTableIndex:1,
	code0:19,
	code1:0,
	value:'19',
	modulation:'64QAM',
	quality:'good'
} ]);

assert.deepStrictEqual(mcs.parse('0,1,0,15,31,1,7,255|0,0,1,0,29'), [
	{ index:1, rat:'NR', mcsTableIndex:0, code0:15, code1:31, value:'15', modulation:'16QAM', quality:'fair' },
	{ index:2, rat:'NR', mcsTableIndex:1, code0:7, code1:255, value:'7', modulation:'QPSK', quality:'weak' },
	{ index:3, rat:'LTE', mcsTableIndex:1, code0:0, code1:29, value:'0', modulation:'QPSK', quality:'weak' }
]);

assert.deepStrictEqual(mcs.parse('0,1,0,0,255')[0], {
	index:1,
	rat:'NR',
	mcsTableIndex:0,
	code0:0,
	code1:255,
	value:'0',
	modulation:'QPSK',
	quality:'weak'
});

assert.deepStrictEqual(mcs.parse(''), []);
assert.deepStrictEqual(mcs.parse('0,1,0,255,24,1,15,255').map(record => record.value), [ '', '15' ]);
assert.strictEqual(mcs.label(mcs.parse('0,1,0,15,31')[0]), 'MCS 15 16QAM');
assert.strictEqual(mcs.label(mcs.parse('0,1,0,255,24')[0]), '--');
console.log('MCS parser tests passed');

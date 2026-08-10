const test = require('node:test');
const assert = require('node:assert/strict');
const { csvFields, parseMetrics } = require('../src/collector');

test('csvFields 支持带逗号和转义引号的字段', () => {
  assert.deepEqual(csvFields('0, "GPU, Pro", "a""b"'), ['0', 'GPU, Pro', 'a"b']);
});

test('parseMetrics 解析系统指标和多块 GPU', () => {
  const output = `HOSTNAME=compute-01
CPU_PERCENT=37.5
MEM_TOTAL_KIB=67108864
MEM_USED_KIB=16777216
MEM_PERCENT=25.0
LOAD_1=1.20
LOAD_5=1.10
LOAD_15=0.90
UPTIME_SECONDS=172861
GPUS_BEGIN
0, NVIDIA GeForce RTX 3090, GPU-aaa, 72, 12000, 24576, 68, 280.5, 350.0, 77
1, NVIDIA RTX A6000, GPU-bbb, 0, 100, 49140, 31, [N/A], 300.0, 30
GPUS_END`;

  const metrics = parseMetrics(output);
  assert.equal(metrics.hostname, 'compute-01');
  assert.equal(metrics.cpu.utilization, 37.5);
  assert.equal(metrics.memory.usedMiB, 16384);
  assert.equal(metrics.memory.totalMiB, 65536);
  assert.equal(metrics.gpus.length, 2);
  assert.equal(metrics.gpus[0].name, 'NVIDIA GeForce RTX 3090');
  assert.equal(metrics.gpus[1].powerDrawW, null);
});

test('parseMetrics 拒绝不完整输出', () => {
  assert.throws(() => parseMetrics('HOSTNAME=node-only'), /输出不完整/);
});


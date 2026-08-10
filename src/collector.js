const { spawn } = require('node:child_process');

const REMOTE_SCRIPT = String.raw`#!/bin/sh
read _ u1 n1 s1 i1 w1 q1 sq1 st1 rest < /proc/stat
t1=$((u1+n1+s1+i1+w1+q1+sq1+st1))
z1=$((i1+w1))
sleep 0.2
read _ u2 n2 s2 i2 w2 q2 sq2 st2 rest < /proc/stat
t2=$((u2+n2+s2+i2+w2+q2+sq2+st2))
z2=$((i2+w2))
cpu=$(awk -v dt=$((t2-t1)) -v di=$((z2-z1)) 'BEGIN { if (dt > 0) printf "%.1f", (dt-di)*100/dt; else print "0.0" }')
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
mem_used=$((mem_total-mem_available))
mem_percent=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN { if (t > 0) printf "%.1f", u*100/t; else print "0.0" }')
set -- $(cat /proc/loadavg)
echo "HOSTNAME=$(hostname)"
echo "CPU_PERCENT=$cpu"
echo "MEM_TOTAL_KIB=$mem_total"
echo "MEM_USED_KIB=$mem_used"
echo "MEM_PERCENT=$mem_percent"
echo "LOAD_1=$1"
echo "LOAD_5=$2"
echo "LOAD_15=$3"
echo "UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)"
echo "GPUS_BEGIN"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null || true
fi
echo "GPUS_END"
`;

function csvFields(line) {
  const fields = [];
  let value = '';
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (char === ',' && !quoted) {
      fields.push(value.trim());
      value = '';
    } else {
      value += char;
    }
  }
  fields.push(value.trim());
  return fields;
}

function numberOrNull(value) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseMetrics(output) {
  const values = {};
  const gpuLines = [];
  let readingGpus = false;

  for (const rawLine of output.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === 'GPUS_BEGIN') {
      readingGpus = true;
    } else if (line === 'GPUS_END') {
      readingGpus = false;
    } else if (readingGpus && line) {
      gpuLines.push(line);
    } else {
      const separator = line.indexOf('=');
      if (separator > 0) values[line.slice(0, separator)] = line.slice(separator + 1);
    }
  }

  const gpus = gpuLines.map((line) => {
    const fields = csvFields(line);
    return {
      index: numberOrNull(fields[0]),
      name: fields[1] || 'NVIDIA GPU',
      uuid: fields[2] || null,
      utilization: numberOrNull(fields[3]),
      memoryUsedMiB: numberOrNull(fields[4]),
      memoryTotalMiB: numberOrNull(fields[5]),
      temperatureC: numberOrNull(fields[6]),
      powerDrawW: numberOrNull(fields[7]),
      powerLimitW: numberOrNull(fields[8]),
      fanPercent: numberOrNull(fields[9])
    };
  });

  if (!values.HOSTNAME || numberOrNull(values.CPU_PERCENT) === null) {
    throw new Error('远程指标输出不完整');
  }

  return {
    hostname: values.HOSTNAME,
    cpu: { utilization: numberOrNull(values.CPU_PERCENT) },
    memory: {
      usedMiB: numberOrNull(values.MEM_USED_KIB) / 1024,
      totalMiB: numberOrNull(values.MEM_TOTAL_KIB) / 1024,
      percent: numberOrNull(values.MEM_PERCENT)
    },
    load: {
      one: numberOrNull(values.LOAD_1),
      five: numberOrNull(values.LOAD_5),
      fifteen: numberOrNull(values.LOAD_15)
    },
    uptimeSeconds: numberOrNull(values.UPTIME_SECONDS),
    gpus
  };
}

function collectServer(host, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const child = spawn('ssh', [
      '-T',
      '-o', 'BatchMode=yes',
      '-o', `ConnectTimeout=${Math.max(1, Math.ceil(timeoutMs / 1000))}`,
      host,
      'sh', '-s'
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });

    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      reject(new Error(`SSH 采集超时（${timeoutMs} ms）`));
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error(`无法启动 SSH: ${error.message}`));
    });
    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(stderr.trim() || `SSH 退出码 ${code}`));
        return;
      }
      try {
        resolve({ metrics: parseMetrics(stdout), latencyMs: Date.now() - startedAt });
      } catch (error) {
        reject(error);
      }
    });

    child.stdin.end(REMOTE_SCRIPT);
  });
}

module.exports = { collectServer, parseMetrics, csvFields, REMOTE_SCRIPT };


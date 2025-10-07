// worker.js


const { Worker, QueueScheduler, Queue } = require('bullmq');
const IORedis = require('ioredis');
const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const fs = require('fs-extra');
const tmp = require('tmp-promise');
const { spawn } = require('child_process');
const fetch = require('node-fetch');
const crypto = require('crypto');
const pino = require('pino');


/**
 ENV vars expected:
 REDIS_URL
 S3_ENDPOINT, S3_REGION, S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET
 API_NOTIFY_URL (optional) - POST updates for job state
 JOB_TIMEOUT_MS (optional)
 MAX_CONCURRENCY (BullMQ concurrency)
*/

const redis = new IORedis(process.env.REDIS_URL || "redis://127.0.0.1:6379");
const queueName = process.env.QUEUE_NAME || "libreoffice";

new QueueScheduler(queueName, { connection: redis });

const s3 = new S3Client({
  region: process.env.S3_REGION || "us-east-1",
  endpoint: process.env.S3_ENDPOINT,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY,
    secretAccessKey: process.env.S3_SECRET_KEY,
  },
  forcePathStyle: true,
});

const bucket = process.env.S3_BUCKET || "conversions";
const JOB_TIMEOUT_MS = Number(process.env.JOB_TIMEOUT_MS || 5 * 60 * 1000); // 5 min
const MAX_CONCURRENCY = Number(process.env.MAX_CONCURRENCY || 1);

function sha256FilePath(path) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const rs = fs.createReadStream(path);
    rs.on("error", reject);
    rs.on("data", (d) => hash.update(d));
    rs.on("end", () => resolve(hash.digest("hex")));
  });
}

async function downloadFromS3(key, outPath) {
  const cmd = new GetObjectCommand({ Bucket: bucket, Key: key });
  const res = await s3.send(cmd);
  // stream to file
  await fs.ensureDir(pathDir(outPath));
  const ws = fs.createWriteStream(outPath);
  await new Promise((resolve, reject) => {
    res.Body.pipe(ws)
      .on("finish", resolve)
      .on("error", reject);
  });
}

// helper to create directories safely
function pathDir(p) {
  return require("path").dirname(p);
}

async function uploadToS3(filePath, key) {
  const body = fs.createReadStream(filePath);
  const cmd = new PutObjectCommand({ Bucket: bucket, Key: key, Body: body });
  await s3.send(cmd);
}

async function notifyApi(jobId, payload) {
  if (!process.env.API_NOTIFY_URL) return;
  try {
    await fetch(`${process.env.API_NOTIFY_URL}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jobId, ...payload }),
    });
  } catch (err) {
    log.warn({ err }, "failed to notify API");
  }
}

function spawnSofficeConvert(inputPath, outDir, targetFormat, timeoutMs = JOB_TIMEOUT_MS) {
  // soffice --headless --convert-to docx --outdir /out /in/file.pdf
  const args = [
    "--headless",
    "--convert-to",
    targetFormat,
    "--outdir",
    outDir,
    inputPath,
  ];

  log.info({ args }, "spawning soffice");
  const child = spawn("soffice", args, { stdio: ["ignore", "pipe", "pipe"] });

  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => (stdout += d.toString()));
  child.stderr.on("data", (d) => (stderr += d.toString()));

  let killed = false;
  const timer = setTimeout(() => {
    killed = true;
    child.kill("SIGKILL");
  }, timeoutMs);

  return new Promise((resolve, reject) => {
    child.on("close", (code) => {
      clearTimeout(timer);
      if (killed) {
        return reject(new Error("soffice timed out"));
      }
      if (code !== 0) {
        return reject(new Error(`soffice exited ${code}: ${stderr.slice(0, 2000)}`));
      }
      resolve({ stdout, stderr });
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

const worker = new Worker(
  queueName,
  async (job) => {
    /**
     job.data expected shape:
     {
       jobId: string,
       s3InputKey: string, // path to uploaded PDF in S3
       inputChecksum?: string,
       outputs: [{ format: "docx"|"pptx", options: {...} }],
       callbackUrl?: string, // optional per-job override
     }
    */
    const { jobId, s3InputKey, inputChecksum, outputs = [] } = job.data;
    log.info({ jobId, s3InputKey }, "picked up job");

    const tmpdir = await tmp.dir({ unsafeCleanup: true, prefix: `job-${jobId}-` });
    try {
      // 1) download input
      const inputLocal = `${tmpdir.path}/input.pdf`;
      log.info({ jobId }, "downloading input from S3");
      const getCmd = new GetObjectCommand({ Bucket: bucket, Key: s3InputKey });
      const res = await s3.send(getCmd);
      await fs.ensureDir(pathDir(inputLocal));
      await new Promise((resolve, reject) => {
        const ws = fs.createWriteStream(inputLocal);
        res.Body.pipe(ws).on("finish", resolve).on("error", reject);
      });

      // 2) checksum / idempotency check
      const actualChecksum = await sha256FilePath(inputLocal);
      if (inputChecksum && inputChecksum !== actualChecksum) {
        throw new Error("checksum_mismatch");
      }

      // (OPTIONAL) 3) virus scan - integrate ClamAV CLI here (scan inputLocal)
      // e.g., spawn clamscan -r --no-summary inputLocal

      const results = [];
      for (const out of outputs) {
        const fmt = out.format;
        // libreoffice uses 'docx' for convert-to argument. For pptx same.
        // ensure format mapping safe
        const safeFormat = fmt.toLowerCase();
        const outDir = `${tmpdir.path}/out-${safeFormat}`;
        await fs.ensureDir(outDir);

        // run soffice conversion
        log.info({ jobId, fmt }, "starting soffice convert");
        await notifyApi(jobId, { status: "converting", format: safeFormat });
        await spawnSofficeConvert(inputLocal, outDir, safeFormat);

        // soffice writes file(s) to outDir; find them
        const files = await fs.readdir(outDir);
        if (files.length === 0) {
          throw new Error("conversion_no_output");
        }

        // upload each file created (usually one)
        for (const f of files) {
          const local = `${outDir}/${f}`;
          // construct S3 key, e.g., results/jobId/<format>/<filename>
          const resultKey = `results/${jobId}/${safeFormat}/${f}`;
          log.info({ jobId, resultKey }, "uploading conversion result");
          await uploadToS3(local, resultKey);
          results.push({ format: safeFormat, key: resultKey, filename: f, size: (await fs.stat(local)).size });
        }
      }

      // mark success: notify API with result keys
      await notifyApi(jobId, { status: "completed", results });
      return { results };
    } catch (err) {
      log.error({ err, jobId }, "job failed");
      await notifyApi(jobId, { status: "failed", error: String(err).slice(0, 2000) });
      throw err; // bubble to BullMQ to trigger retries per queue config
    } finally {
      // safe cleanup
      try {
        await tmpdir.cleanup();
      } catch (e) {
        log.warn({ e }, "cleanup failed");
      }
    }
  },
  {
    connection: redis,
    concurrency: MAX_CONCURRENCY,
    lockDuration: 60_000, // lock duration in ms (tune)
  }
);

worker.on("completed", (job) => {
  log.info({ id: job.id }, "job completed (worker event)");
});

worker.on("failed", (job, err) => {
  log.warn({ id: job?.id, err: err?.message }, "job failed (worker event)");
});

// graceful shutdown
process.on("SIGTERM", async () => {
  log.info("SIGTERM received, closing worker");
  await worker.close();
  process.exit(0);
});

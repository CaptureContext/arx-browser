"""Compile out Chrome's metrics-only TPM benchmark on macOS (DEV-894).

`ChromeBrowserMainExtraPartsMetrics::PostBrowserStart` runs on every launch and
posts `crypto::MaybeMeasureTpmOperations` 45 seconds later. Chromium 157
samples it on Stable, but an unbranded build's channel is unknown, so Helium
and Arx run it every time. It creates, signs with and deletes Secure Enclave
keys in the login keychain only to record `Crypto.TPM*` histograms (about
0.6 s of browser-process CPU per launch). Helium and Arx upload no metrics, so
the benchmark is pure cost. The call stays on Windows, where Arx doesn't build.
Device-bound session keys and every other caller of the unexportable-key
provider are unchanged. If the anchor changes, the build stops instead of
shipping the benchmark.
"""
from .overlay import replace_once

METRICS = "chrome/browser/metrics/chrome_browser_main_extra_parts_metrics.cc"

TPM = """#if BUILDFLAG(IS_WIN) || BUILDFLAG(IS_MAC)
  // Deliberately delayed and sampled to avoid contending with early crypto and
  // DBSC operations right after startup. The measurement runs slow TPM
  // operations, which must not block shutdown.
  if (base::ShouldRecordSubsampledMetric(
          GetTpmMetricsSamplingProbability(chrome::GetChannel()))) {
    base::ThreadPool::PostDelayedTask(
        FROM_HERE,
        {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce(&crypto::MaybeMeasureTpmOperations,
                       unexportable_keys::GetDefaultConfig()),
        base::Seconds(45));
  }
#endif  // BUILDFLAG(IS_WIN) || BUILDFLAG(IS_MAC)
"""

ARX_TPM = """  // Arx (DEV-894): no TPM benchmark on macOS. It only records histograms,
  // which Arx never uploads, and makes Secure Enclave keys.
#if BUILDFLAG(IS_WIN)
  // Deliberately delayed and sampled to avoid contending with early crypto and
  // DBSC operations right after startup. The measurement runs slow TPM
  // operations, which must not block shutdown.
  if (base::ShouldRecordSubsampledMetric(
          GetTpmMetricsSamplingProbability(chrome::GetChannel()))) {
    base::ThreadPool::PostDelayedTask(
        FROM_HERE,
        {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
         base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce(&crypto::MaybeMeasureTpmOperations,
                       unexportable_keys::GetDefaultConfig()),
        base::Seconds(45));
  }
#endif  // BUILDFLAG(IS_WIN)
"""


def patches():
    yield METRICS, TPM, ARX_TPM


def apply(source):
    for relative, before, after in patches():
        replace_once(source / relative, before, after)

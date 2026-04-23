// k6/lib/options.js
//
// Runtime dispatch from the BENCH_LOAD_PROFILE env var to the matching
// `k6/profiles/*.js` options object. Re-exports the chosen profile's
// `options` so every scenario can write a single line:
//
//   import { options } from '../lib/options.js';
//   export { options };
//
// k6's `import` is static (resolved at script-parse time, before
// `options` is read), so all four profile files must be imported up
// front. Only one is selected at runtime via env. Adding a new load
// profile means: (a) drop a `pX-name.js` file under `k6/profiles/`,
// (b) add it to the `profileMap` below, (c) document it in
// `docs/LOAD-PROFILES.md`. In that order.
//
// The runner script (`scripts/load-gateway.sh`) is the canonical
// source of valid BENCH_LOAD_PROFILE values; an unknown value here
// becomes a hard `Error` thrown during k6's init phase, which fails
// the run cleanly before any traffic is generated.

import { options as p1Baseline  } from '../profiles/p1-baseline.js';
import { options as p1cPaced    } from '../profiles/p1c-paced.js';
import { options as p2Sustained } from '../profiles/p2-sustained.js';
import { options as p2cPaced    } from '../profiles/p2c-paced.js';
import { options as p3Ramp      } from '../profiles/p3-ramp.js';
import { options as p3cPaced    } from '../profiles/p3c-paced.js';
import { options as p4Stress    } from '../profiles/p4-stress.js';
import { options as p4cPaced    } from '../profiles/p4c-paced.js';

import { loadProfile, gatewayName, policyProfile, scenarioName, runId } from './env.js';

// The `-paced` suffix in a profile slug IS the gate for opting into
// the `constant-arrival-rate` / `ramping-arrival-rate` executors;
// there is no separate BENCH_ARRIVAL env var. Closed-loop twins
// (no suffix) keep the original shape byte-for-byte — adding paced
// entries below does not alter the closed-loop code path at all.
// See docs/LOAD-PROFILES.md § Paced-arrivals variants for the why.
const profileMap = {
    'p1-baseline':  p1Baseline,
    'p1c-paced':    p1cPaced,
    'p2-sustained': p2Sustained,
    'p2c-paced':    p2cPaced,
    'p3-ramp':      p3Ramp,
    'p3c-paced':    p3cPaced,
    'p4-stress':    p4Stress,
    'p4c-paced':    p4cPaced,
};

const selectedSlug = loadProfile();
const selected = profileMap[selectedSlug];
if (!selected) {
    throw new Error(
        `[k6/lib/options] unknown BENCH_LOAD_PROFILE='${selectedSlug}'. ` +
        `Valid values: ${Object.keys(profileMap).join(', ')}.`,
    );
}

// Tag every metric with the four cell-coordinates so the summary JSON
// is fully self-describing — the orchestrator post-processor and the
// report generator both group by these. Tags are merged into whatever
// the profile already declares, so per-profile thresholds win where
// they overlap.
const cellTags = {
    bench_gateway:  gatewayName(),
    bench_policy:   policyProfile(),
    bench_scenario: scenarioName(),
    bench_load:     selectedSlug,
    bench_run_id:   runId(),
};

export const options = {
    ...selected,
    tags: {
        ...(selected.tags || {}),
        ...cellTags,
    },
};

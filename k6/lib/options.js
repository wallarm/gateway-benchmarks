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
import { options as p2Sustained } from '../profiles/p2-sustained.js';
import { options as p3Ramp      } from '../profiles/p3-ramp.js';
import { options as p4Stress    } from '../profiles/p4-stress.js';

import { loadProfile, gatewayName, policyProfile, scenarioName, runId } from './env.js';

const profileMap = {
    'p1-baseline':  p1Baseline,
    'p2-sustained': p2Sustained,
    'p3-ramp':      p3Ramp,
    'p4-stress':    p4Stress,
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

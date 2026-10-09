# Python reference implementation

The project was prototyped here before being ported to R. These scripts are
kept for two reasons:

1. **Validation.** They produce the same payload shape, so a questionable R
   result can be diffed against a known-good one. See `validate.R`.
2. **The backtest.** `backtest.py` reproduces the threshold validation
   described in the README. It has not been ported to R.

The R chain in `../build.R` is the real pipeline. Nothing here needs to run
for the dashboard to build.

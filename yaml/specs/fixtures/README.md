# yaml-test-suite

`../fetch-suite.sh` (run by `make install PACKAGES=yaml`) fetches the [yaml-test-suite](https://github.com/yaml/yaml-test-suite) (MIT) at commit `6ad3d2c62885d82fc349026c136ef560838fdf3d` of its `data` branch (release `data-2022-01-17`), checks the sha256 of the archive and unpacks it into `yaml/.cache/` (ignored by git). `suite.agc` runs the 357 cases in scope. Left out:

- the 29 cases with no `in.json` and no `error`: their keys are null or a collection, which JSON cannot hold;
- custom and local tags: 5TYM 6CK3 6WLZ 7FWL 9WXW C4HZ CC74 CUP7 M5C3 P76L UGM3 Z67P Z9M4;
- the YAML 1.1 types `!!set`, `!!omap` and `!!binary`: 2XXW J7PZ 565N.

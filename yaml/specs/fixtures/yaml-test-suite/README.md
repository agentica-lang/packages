# yaml-test-suite (a copy)

The cases of the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite) that are in the scope of this
package, taken from its `data` branch at commit `6ad3d2c62885d82fc349026c136ef560838fdf3d` (the release
`data-2022-01-17`). The suite is under the MIT license (`LICENSE` in this folder).

Each folder is one case, named by its id (a case with several parts is `ID-NN`): `in.yaml`, and either `in.json` (the
values of its documents, one JSON value after another) or an empty `error` file (the text is invalid YAML). Only those
files are copied; `../suite.agc` runs the cases, and `../../suite.feature` asserts the count.

Copied: 357 cases, 263 with `in.json` and 94 with `error`.

Left out:

- The 29 cases that have no `in.json` and no `error`: their keys are null or a collection, which JSON cannot hold (this
  package refuses such a key). 2JQS 4ABK 4FJ6 6BFJ 6M2F 6PBE 9MMW CFD4 DFF7 FH7J FRK4 KK5P LX3P M2N8-00 M2N8-01 M5DY
  NHX8 NKF9 PW8X Q9WF RZP5 S3PD SBG9 SM9W-01 UKK6-00 UKK6-02 V9D5 X38W XW4D.
- Custom and local tags (`!foo`, `!local`, `%TAG` prefixes to other URIs, verbatim tags that are not core): 5TYM 6CK3
  6WLZ 7FWL 9WXW C4HZ CC74 CUP7 M5C3 P76L UGM3 Z67P Z9M4.
- The YAML 1.1 types `!!set`, `!!omap` and `!!binary`: 2XXW J7PZ 565N.

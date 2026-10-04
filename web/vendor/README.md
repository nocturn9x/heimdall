# chess.js

`chess.js` is the unmodified browser ESM distribution from
[chess.js 1.4.0](https://github.com/jhlywa/chess.js/tree/v1.4.0), downloaded from
<https://registry.npmjs.org/chess.js/-/chess.js-1.4.0.tgz>.
It supplies standard chess rules and PGN parsing; Heimdall supplies the engine.
The accompanying `chess.LICENSE` is the upstream BSD-2-Clause license.

The npm tarball integrity is:

```text
sha512-BBJgrrtKQOzFLonR0l+k64A98NLemPwNsCskwb+29bRwobUa4iTm51E1kwGPbWXAcfdDa18nad6vpPPKPWarqw==
```

To update, replace `package/dist/esm/chess.js` and `package/LICENSE` from a pinned
npm release, update this record, and run the browser regression test. Assets are
served locally; the website has no runtime dependency on a CDN.

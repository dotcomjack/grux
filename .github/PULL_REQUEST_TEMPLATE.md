## What this changes

<!-- One concern per pull request. What is different afterwards, and why. -->

## How you verified it

<!--
An artifact beats an assertion. A quoted line of output, an exit code, a path, a
screenshot. "Tested locally" tells a reviewer nothing they can check.

`swift build` does NOT compile the test target, so please paste the
`Executed N tests` line rather than the build result.
-->

- [ ] `swift build` succeeds
- [ ] `swift test` runs, and I have pasted the `Executed N tests` line
- [ ] `python3 scripts/check-contract.py` passes
- [ ] No em dashes or en dashes, comments included

Test output:

```
paste the Executed N tests line here
```

## If a guard failed

<!--
If your change made an existing test fail, say why the guard was wrong rather
than widening it until it goes quiet. Several tests here assert exact counts and
sets deliberately, so one firing is usually asking for a written decision.
-->

## If this changes what a feature requires

<!--
Adding, removing or changing a credential, permission, endpoint or setup step
needs a dated amendment to the setup contract in Grux-Mac/docs/, not an edit to
an existing entry. CR-29, CR-30 and CR-31 are the precedent. Link yours here.
-->

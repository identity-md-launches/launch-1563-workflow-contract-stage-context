# Vendored dependencies and provenance

All files needed by the contracts, tests, and keeper runtime are ordinary repository files. There are no git submodules, npm installs, external library links, or network imports in normal build/test paths.

| Source | Pinned version / revision | Included content |
|---|---|---|
| [CAT WARS specification](https://github.com/dew1645/cat-wars-spec/tree/62a025e1bfd655205aa1cdb54ce9943999691c85) | `62a025e1bfd655205aa1cdb54ce9943999691c85` | Verbatim engine, verbatim Foundry engine test, verbatim 500-vector JSON, specification snapshot |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7, `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, MIT and Apache licenses |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527) | v5.2.0, `acd4ff74de833399287ed6b31b4debf6b2b35527` | ERC20, Ownable2Step, ReentrancyGuard, Pausable, Math and their import closure; MIT license |
| [Chainlink EVM](https://github.com/smartcontractkit/chainlink-evm/tree/e06cc226086ad91cfede63e96c63e5b3440c9801) | contracts-v1.4.0, `e06cc226086ad91cfede63e96c63e5b3440c9801` | Wrapper consumer base, wrapper interface, VRFV2PlusClient, LINK interface and license |
| [viem](https://github.com/wevm/viem) | npm 2.38.5 | Self-contained ESM bundle with transitive dependencies; exact package versions, archive URLs and integrity digests in `keeper/vendor/packages.json` |

The three required reference-file SHA-256 hashes are:

```text
3bfa607de3d6a363e0e0f6cc47f4eaa799f4e6cf5baf72a74de8acbce9d7d894  src/CatWarsEngine.sol
0b2d485a8c8ad40d79b44462c5e52012b95b4c5db827c92349ec93f9f089e274  test/CatWarsEngine.t.sol
42f05f732496ae80c55fcf1b225fb4a385b5ab4d9a735c37b019fdeea3e77d2e  test/vectors.json
```

OpenZeppelin and forge-std sources are unmodified. Chainlink's wrapper base has exactly this adaptation:

1. Remove `LinkTokenInterface internal immutable i_linkToken`.
2. Remove the constructor's `wrapper.link()` call; keep the wrapper immutable assignment.
3. Make `getLinkToken()` resolve `LinkTokenInterface(i_vrfV2PlusWrapper.link())` at runtime.
4. Make the unused LINK-payment helper use `getLinkToken().transferAndCall(...)`.

The native request helper and callback authentication are unchanged. The original file is saved at `docs/reference/VRFV2PlusWrapperConsumerBase.upstream.txt`, permitting an exact local diff. This modification is required by the launch's prohibition on external constructor calls, not by a change in VRF behavior.

The viem bundle is produced by the pinned esbuild 0.25.11 package. `tools/bundle-keeper.py` verifies every npm archive's integrity before unpacking or executing the bundler. Only the finished runtime, license notices, integrity lock, and reproducible maintenance script are needed in this contribution. No compiler executable is delivered. Licenses for included JS dependencies are under `keeper/vendor/licenses/`; the bundle retains its generated legal notices. `keeper/vendor/viem.sha256` records its output hash.

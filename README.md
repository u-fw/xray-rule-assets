# xray-rule-assets

Xray rule assets and related automation scripts.

## 1stream.dat

This repository can manually build `1stream.dat` with GitHub Actions.

The generated file is a geosite/domain asset for Xray `domain` rules. It does not contain geoip data.

### Build

Run the `Build 1stream.dat` workflow manually from the GitHub Actions page.

The workflow publishes these files to the `1stream-latest` release:

- `1stream.dat`
- `1stream.dat.sha256`
- `1stream-tags.md`
- `source-info.json`

### Xray Usage

Download `1stream.dat` to Xray's asset directory, usually `/usr/local/share/xray`.

Example routing rule:

```json
{
  "type": "field",
  "domain": [
    "ext:1stream.dat:ai"
  ],
  "outboundTag": "proxy"
}
```

Download `1stream-tags.md` from the release to see all generated tags.

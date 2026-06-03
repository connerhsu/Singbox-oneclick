# Singbox Oneclick

One-click sing-box installer with selectable SS2022 + ShadowTLS, AnyTLS, and VLESS Reality menu management.

## Install

Interactive selection:

```bash
curl -fsSL https://raw.githubusercontent.com/connerhsu/Singbox-oneclick/main/singbox-oneclick-menu.sh -o /tmp/singbox-oneclick-menu.sh && sudo bash /tmp/singbox-oneclick-menu.sh install
```

Install one protocol directly:

```bash
sudo bash /tmp/singbox-oneclick-menu.sh install ss2022-shadowtls
sudo bash /tmp/singbox-oneclick-menu.sh install anytls
sudo bash /tmp/singbox-oneclick-menu.sh install vless-reality
```

Install multiple protocols:

```bash
sudo bash /tmp/singbox-oneclick-menu.sh install 1 3
```

After installation, open the panel with:

```bash
menu
```

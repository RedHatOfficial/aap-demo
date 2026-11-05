---
type: Guide
title: Subscription
description: What AAP does without a subscription, how to get a manifest, and how to apply it.
tags: [subscription, license, manifest]
status: draft
stale_after: 2027-01-28
resource: https://github.com/RedHatOfficial/aap-demo
---

# Subscription

AAP installs and opens without a subscription, so you can skip this page until you need one. AAP won't add hosts
until it has one, and that includes registering [Fleet machines](addons.md).

Nothing is applied unless you choose to, because applying a subscription uses its capacity.

## Choose how to apply it

| Option | Best when |
| --- | --- |
| [Sign in through the AAP web page](#apply-it-in-the-aap-web-page) | You want to do it once, by hand |
| [Give `aap-demo` a manifest file](#apply-a-manifest-with-aap-demo) | You rebuild clusters often |

## Apply it in the AAP web page

Run `aap-demo status` for the address and admin password, and sign in. Go to **Settings** > **Subscription**, and
sign in with your Red Hat account, or upload a manifest. You can do this at any time.

## Get a manifest

A manifest is a `.zip` file holding your subscription. You need an account with an AAP subscription.

1. Open [Subscription Allocations](https://access.redhat.com/management/subscription_allocations).
2. Click **New Subscription Allocation**, give it a name, and pick the newest **Satellite** type.
3. Open it, go to **Subscriptions** > **Add Subscriptions**, and enter a quantity on an AAP subscription that is
   **active today**.
4. Go to **Details** and click **Export Manifest**.

The quantity is how many hosts the manifest covers. Whatever you assign can't be used elsewhere in your organization
until you remove it, so ask first if the subscription is shared.

The **Manifests** page on `console.redhat.com` won't work for this. It can't add subscriptions to a manifest.

## Apply a manifest with aap-demo

Save the file in `~/.config/aap-demo/`. Keep the name it downloaded with, and keep it private:

```bash
mkdir -p ~/.config/aap-demo
cp ~/Downloads/manifest_*.zip ~/.config/aap-demo/
chmod 600 ~/.config/aap-demo/manifest_*.zip
```

Then deploy. This also works on an AAP that is already running:

```bash
aap-demo deploy --auto-license
```

Without `--auto-license`, `deploy` asks first, and the answer defaults to no. With no terminal to ask in, or with
`--yes`, it leaves AAP as it is and tells you how to apply the manifest.

To apply it every time without asking:

```bash
aap-demo config set auto-license true
```

### Where aap-demo looks

`aap-demo` uses the first of these that it finds. It only reads the file, and never moves or copies it.

1. `--manifest PATH`
2. The `AAP_DEMO_MANIFEST` environment variable
3. The saved path, from `aap-demo config set manifest PATH`
4. The newest `manifest*.zip` in `~/.config/aap-demo/`
5. The newest `manifest*.zip` in `~/.local/state/aap-demo/`
6. The newest `manifest*.zip` in `~/.aap-demo/`, the older command's folder

An AAP that already has a subscription is left alone. Delete the `.zip` from your Downloads folder afterward: it is
a credential, so don't commit it or share it.

## If it doesn't work

| What you see | What to do |
| --- | --- |
| `Invalid subscription` | Check that the manifest holds a subscription active today. One that starts later is rejected. Export a new one. |
| `You can't add subscriptions` on the Manifests page | Use [Subscription Allocations](#get-a-manifest) instead. |
| `AAP has no subscription, so it can't register Fleet hosts` | Apply a subscription, then run `aap-demo enable fleet` again. Or use `aap-demo enable fleet --no-import`. |

A problem with a manifest shows as a warning. `deploy` still finishes, because AAP works without one.

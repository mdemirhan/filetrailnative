# Lighthouse

Plan a trip with friends: *where* you are going, *when*, and **who** is coming along.

## What it does

- **Trips** with stops on a map, dates and a cover photo
- **Shared plans**: everyone on the trip sees changes as they are made
- **Offline first**: edits are kept on the device until it is back online

## What's inside

| Part | Built with | Folder |
|:---|:---|:---|
| Web app | React and Vite | `app/` |
| Mobile app | React Native | `mobile/` |
| API | Bun and SQLite | `infra/api/` |

## Getting started

1. Install [Bun](https://bun.sh) 1.2 or later.
2. Copy `.env.example` to `.env` and add your map key.
3. Start the web app and the API together:

```sh
bun install
bun run dev
```

> The mobile app has its own steps in `mobile/README.md`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first, then open a pull request against `main`.

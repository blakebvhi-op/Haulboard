# HaulBoard — junk car pickup dispatch

Single-file PWA (same stack as Better View Pro: vanilla HTML/JS + Supabase REST). Rebuilt clean from the BV Pro snow plow module, but for one-off car pickups instead of recurring plow accounts.

## Files
- `app.html` — the whole app (auth, pickups, dispatch board, driver run page, money, settings)
- `schema.sql` — Supabase tables, RLS, and signup/join RPCs. Run once in the SQL editor.
- `manifest.webmanifest`, `sw.js`, `icon-*.png` — PWA bits so it installs to a phone home screen and opens offline
- `index.html` — redirect to app.html (for GitHub Pages)

## Try it right now
Open `app.html` in a browser. With `SB_URL` empty it runs in **demo mode** — sample data in localStorage, a "view as" switcher in Settings to see the owner vs. driver experience.

## Go live
1. New Supabase project → SQL editor → paste `schema.sql` → Run.
2. Project Settings → API → copy the URL and anon key into `SB_URL` / `SB_KEY` at the top of the `<script>` in `app.html`.
3. Auth → Providers → Email: turn **off** "Confirm email" (or leave it on — the app handles both paths).
4. Push to a GitHub Pages repo. Open the URL, create an account as "Starting a company".
5. Settings → copy the join code. Drivers sign up on the same URL as "Joining as a driver" and enter the code.

## How it works
**Roles:** owner (everything), dispatcher (everything but team/company settings), driver (My Run + read-mostly pickups).

**Pickup lifecycle:** `new` (needs a truck) → `scheduled` (date + driver, lives on a run) → `done` (driver tapped Arrived → Loaded & paid) or `cancelled`. If a driver can't get a car it goes back to `new` with a note.

**Runs:** one driver, one day, ordered `stop_ids`. Created automatically when you assign a pickup to a driver+date, or manually from the board. ▲▼ sets the order the Maps link uses (split into 10-stop legs like the plow tool).

**Money:** payout is recorded by the driver on the spot. Owner later fills in "Sold to yard" (yard, price, date) and the Money tab shows margin per period and per driver.

**Offline:** reads come from localStorage cache first; writes go through a debounced queue that retries when the connection comes back (same pattern as BV Pro's `queueSave`).

## Not built yet (ideas)
- Photos per pickup (needs Supabase Storage)
- Customer-facing "get an offer" form that creates `new` pickups
- Title/bill-of-sale PDF generation at the truck
- Push notifications when a run is assigned

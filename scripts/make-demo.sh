#!/bin/zsh
# Creates demo sessions for screenshots and the launch GIF, without a VM:
# small sample projects, sessions made with `mudroom new`, and agent edits
# written straight into each session's work/ copy.
#
#   scripts/make-demo.sh                 # into build/demo
#   MUDROOM_HOME=build/demo/store build/Mudroom.app/Contents/MacOS/Mudroom -MudroomFocus src/api.ts
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=${DEMO_ROOT:-$PWD/build/demo}
export MUDROOM_HOME=$ROOT/store
M=${MUDROOM:-$PWD/.build/debug/mudroom}
[[ -x $M ]] || swift build --product mudroom

rm -rf "$ROOT"
mkdir -p "$ROOT/projects"

setjson() {  # setjson <session dir> key=value...  (values are JSON)
  python3 - "$@" <<'PY'
import json, sys
d = sys.argv[1]
p = f"{d}/session.json"
s = json.load(open(p))
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    s[k] = json.loads(v)
json.dump(s, open(p, "w"), indent=2, sort_keys=True)
PY
}
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }
snap() {  # snap <session dir> <n> <age>: APFS-clone work/ as snapshot n, taken <age> ago
  mkdir -p "$1/snapshots"
  cp -cR "$1/work" "$1/snapshots/$2-$(date -u -v-"$3" +%Y%m%d-%H%M%S)"
}

# ---------------------------------------------------------------- weather-cli
P=$ROOT/projects/weather-cli
mkdir -p $P/src/legacy $P/tests $P/scripts
cat > $P/package.json <<'EOF'
{
  "name": "weather-cli",
  "version": "1.4.2",
  "description": "Current conditions and forecasts in your terminal",
  "type": "module",
  "bin": { "weather": "dist/cli.js" },
  "scripts": {
    "build": "tsc -p .",
    "test": "vitest run",
    "lint": "eslint src"
  },
  "dependencies": {
    "commander": "^12.1.0",
    "kleur": "^4.1.5"
  },
  "devDependencies": {
    "typescript": "^5.6.2",
    "vitest": "^2.1.1"
  }
}
EOF
cat > $P/README.md <<'EOF'
# weather-cli

Current conditions and a 5-day forecast in your terminal.

## Install

    npm install -g weather-cli

## Usage

    weather "Lisbon"
    weather "Tunis" --units imperial
    weather --forecast "Oslo"

Set `WEATHER_API_KEY` to your OpenWeather key.

## License

MIT
EOF
cat > $P/src/api.ts <<'EOF'
import { Units, Conditions, Forecast } from "./types.js";

const BASE_URL = "https://api.openweathermap.org/data/2.5";

export interface ClientOptions {
  apiKey: string;
  units?: Units;
}

export class WeatherClient {
  private apiKey: string;
  private units: Units;

  constructor(options: ClientOptions) {
    this.apiKey = options.apiKey;
    this.units = options.units ?? "metric";
  }

  async current(city: string): Promise<Conditions> {
    const data = await this.get("/weather", { q: city });
    return {
      city: data.name,
      temperature: data.main.temp,
      feelsLike: data.main.feels_like,
      humidity: data.main.humidity,
      description: data.weather[0].description,
    };
  }

  async forecast(city: string, days = 5): Promise<Forecast[]> {
    const data = await this.get("/forecast", { q: city, cnt: String(days * 8) });
    return data.list
      .filter((_: unknown, i: number) => i % 8 === 0)
      .map((entry: any) => ({
        date: new Date(entry.dt * 1000),
        min: entry.main.temp_min,
        max: entry.main.temp_max,
        description: entry.weather[0].description,
      }));
  }

  private async get(path: string, params: Record<string, string>): Promise<any> {
    const query = new URLSearchParams({ ...params, appid: this.apiKey, units: this.units });
    const response = await fetch(`${BASE_URL}${path}?${query}`);
    if (!response.ok) {
      throw new Error(`Request failed: ${response.status}`);
    }
    return response.json();
  }
}
EOF
cat > $P/src/types.ts <<'EOF'
export type Units = "metric" | "imperial";

export interface Conditions {
  city: string;
  temperature: number;
  feelsLike: number;
  humidity: number;
  description: string;
}

export interface Forecast {
  date: Date;
  min: number;
  max: number;
  description: string;
}
EOF
cat > $P/src/cli.ts <<'EOF'
#!/usr/bin/env node
import { Command } from "commander";
import kleur from "kleur";
import { WeatherClient } from "./api.js";

const program = new Command()
  .name("weather")
  .argument("<city>")
  .option("--units <units>", "metric or imperial", "metric")
  .option("--forecast", "show a 5-day forecast")
  .action(async (city, opts) => {
    const apiKey = process.env.WEATHER_API_KEY;
    if (!apiKey) {
      console.error(kleur.red("Set WEATHER_API_KEY first."));
      process.exit(1);
    }
    const client = new WeatherClient({ apiKey, units: opts.units });
    if (opts.forecast) {
      for (const day of await client.forecast(city)) {
        console.log(`${day.date.toDateString()}  ${day.min}° / ${day.max}°  ${day.description}`);
      }
    } else {
      const now = await client.current(city);
      console.log(`${kleur.bold(now.city)}  ${now.temperature}°  ${now.description}`);
    }
  });

program.parseAsync();
EOF
cat > $P/src/legacy/fetch-v1.js <<'EOF'
// Old XMLHttpRequest client, kept for Node 16. Unused since 1.3.
module.exports = function fetchV1(url, cb) {
  const req = new (require("xmlhttprequest").XMLHttpRequest)();
  req.onload = () => cb(null, JSON.parse(req.responseText));
  req.onerror = (e) => cb(e);
  req.open("GET", url);
  req.send();
};
EOF
cat > $P/tests/api.test.ts <<'EOF'
import { describe, it, expect, vi } from "vitest";
import { WeatherClient } from "../src/api.js";

describe("WeatherClient", () => {
  it("maps current conditions", async () => {
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({
      name: "Lisbon",
      main: { temp: 21, feels_like: 20, humidity: 60 },
      weather: [{ description: "clear sky" }],
    })));
    const client = new WeatherClient({ apiKey: "test" });
    expect((await client.current("Lisbon")).city).toBe("Lisbon");
  });
});
EOF
cat > $P/scripts/release.sh <<'EOF'
#!/bin/sh
set -e
npm test
npm run build
npm publish
EOF
chmod 644 $P/scripts/release.sh
printf 'node_modules/\ndist/\n' > $P/.gitignore
git -C $P init -q -b main && git -C $P add -A && git -C $P -c user.name=demo -c user.email=demo@example.com commit -qm "weather-cli 1.4.2"

ID=$($M new $P --agent "Claude Code" -- claude --dangerously-skip-permissions)
S=$MUDROOM_HOME/sessions/$ID
W=$S/work

# The agent: retries with backoff, a response cache, tests, cleanup.
python3 - $W/src/api.ts <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('''import { Units, Conditions, Forecast } from "./types.js";

const BASE_URL = "https://api.openweathermap.org/data/2.5";
''', '''import { Units, Conditions, Forecast } from "./types.js";
import { ResponseCache } from "./cache.js";

const BASE_URL = "https://api.openweathermap.org/data/2.5";
const MAX_RETRIES = 3;
''')
s = s.replace('''  units?: Units;
}
''', '''  units?: Units;
  /** Cache responses for this many seconds. 0 disables the cache. */
  cacheTtl?: number;
}
''')
s = s.replace('''  private units: Units;

  constructor(options: ClientOptions) {
    this.apiKey = options.apiKey;
    this.units = options.units ?? "metric";
  }
''', '''  private units: Units;
  private cache: ResponseCache;

  constructor(options: ClientOptions) {
    this.apiKey = options.apiKey;
    this.units = options.units ?? "metric";
    this.cache = new ResponseCache(options.cacheTtl ?? 600);
  }
''')
s = s.replace('''  private async get(path: string, params: Record<string, string>): Promise<any> {
    const query = new URLSearchParams({ ...params, appid: this.apiKey, units: this.units });
    const response = await fetch(`${BASE_URL}${path}?${query}`);
    if (!response.ok) {
      throw new Error(`Request failed: ${response.status}`);
    }
    return response.json();
  }''', '''  private async get(path: string, params: Record<string, string>): Promise<any> {
    const query = new URLSearchParams({ ...params, appid: this.apiKey, units: this.units });
    const url = `${BASE_URL}${path}?${query}`;
    const cached = this.cache.get(url);
    if (cached) return cached;

    for (let attempt = 1; ; attempt++) {
      const response = await fetch(url);
      if (response.ok) {
        const body = await response.json();
        this.cache.set(url, body);
        return body;
      }
      if (response.status === 401) {
        throw new Error("Invalid API key. Check WEATHER_API_KEY.");
      }
      if (attempt >= MAX_RETRIES || response.status < 500) {
        throw new Error(`Request to ${path} failed with ${response.status}`);
      }
      await new Promise((r) => setTimeout(r, 250 * 2 ** attempt));
    }
  }''')
open(p, "w").write(s)
PY
snap $S 1 11M

cat > $W/src/cache.ts <<'EOF'
interface Entry {
  value: unknown;
  expires: number;
}

/** In-memory cache keyed by request URL. */
export class ResponseCache {
  private entries = new Map<string, Entry>();

  constructor(private ttlSeconds: number) {}

  get(key: string): any | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expires) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: unknown): void {
    if (this.ttlSeconds <= 0) return;
    this.entries.set(key, { value, expires: Date.now() + this.ttlSeconds * 1000 });
  }
}
EOF
cat > $W/tests/cache.test.ts <<'EOF'
import { describe, it, expect, vi } from "vitest";
import { ResponseCache } from "../src/cache.js";

describe("ResponseCache", () => {
  it("expires entries after the TTL", () => {
    vi.useFakeTimers();
    const cache = new ResponseCache(10);
    cache.set("a", 1);
    expect(cache.get("a")).toBe(1);
    vi.advanceTimersByTime(11_000);
    expect(cache.get("a")).toBeUndefined();
  });
});
EOF
snap $S 2 7M

python3 - $W/README.md <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("Set `WEATHER_API_KEY` to your OpenWeather key.\n",
  "Set `WEATHER_API_KEY` to your OpenWeather key.\n\nResponses are cached for 10 minutes, and failed requests are retried\nup to three times with backoff.\n")
open(p, "w").write(s)
PY
python3 - $W/package.json <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('"version": "1.4.2"', '"version": "1.5.0"')
open(p, "w").write(s)
PY
rm -r $W/src/legacy
chmod 755 $W/scripts/release.sh

# Meanwhile, you bumped a dependency in the real project: a conflict.
sed -i '' 's/"commander": "\^12.1.0"/"commander": "^12.2.0"/' $P/package.json

snap $S 3 3M

# What the VM connected to: the model API, plus npm and the weather API
# the agent tried while running the tests (not on the allowlist).
python3 - $S <<'PY'
import json, sys, datetime, random
d = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
random.seed(7)
rows = []
def at(m): return (now - datetime.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
for i in range(23):
    m = 14 - i * 0.48
    rows.append(dict(time=at(m), host="api.anthropic.com", port=443, method="CONNECT", allowed=True,
                     bytesOut=random.randint(9000, 60000), bytesIn=random.randint(3000, 190000), durationMs=random.randint(1800, 26000)))
for m in (9.2, 9.1, 8.7):
    rows.append(dict(time=at(m), host="registry.npmjs.org", port=443, method="CONNECT", allowed=False,
                     reason="not on this project's allowlist", bytesOut=0, bytesIn=0, durationMs=0))
for m in (6.4, 6.3):
    rows.append(dict(time=at(m), host="api.openweathermap.org", port=443, method="CONNECT", allowed=False,
                     reason="not on this project's allowlist", bytesOut=0, bytesIn=0, durationMs=0))
rows.sort(key=lambda r: r["time"])
with open(f"{d}/network.jsonl", "w") as f:
    for r in rows: f.write(json.dumps(r, sort_keys=True) + "\n")
PY
setjson $S network='{"mode":"locked","enforcement":"enforced","allowlist":["api.anthropic.com","console.anthropic.com","platform.claude.com","claude.ai"],"proxy":"http://192.168.128.1:52140","vmNetwork":"mudroom-hostonly"}'
setjson $S status='"finished"' exitCode=0 started="\"$(ago 14M)\"" finished="\"$(ago 3M)\"" created="\"$(ago 15M)\""

# ---------------------------------------------------------------- api-gateway
G=$ROOT/projects/api-gateway
mkdir -p $G/src
cat > $G/src/server.go <<'EOF'
package main

import (
	"log"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	log.Fatal(http.ListenAndServe(":8080", mux))
}

func health(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("ok"))
}
EOF
printf 'module example.com/gateway\n\ngo 1.23\n' > $G/go.mod
GW_ID=$($M new $G --agent "Codex" -- codex --dangerously-bypass-approvals-and-sandbox)
GS=$MUDROOM_HOME/sessions/$GW_ID
sed -i '' 's/w.Write(\[\]byte("ok"))/w.Header().Set("Content-Type", "text\/plain")\n\tw.Write([]byte("ok"))/' $GS/work/src/server.go
$M apply $GW_ID --all >/dev/null
setjson $GS network='{"mode":"open","enforcement":"none","allowlist":[]}'
setjson $GS exitCode=0 created="\"$(ago 3H)\"" started="\"$(ago 3H)\"" finished="\"$(ago 2H)\""

# An older, discarded attempt on weather-cli, and one still running.
DID=$($M new $P --agent "Gemini CLI" -- gemini --yolo)
$M discard $DID --keep-record >/dev/null
setjson $MUDROOM_HOME/sessions/$DID created="\"$(ago 26H)\""

RID=$($M new $G --agent "Claude Code" -- claude --dangerously-skip-permissions)
echo '// TODO: rate limiting' >> $MUDROOM_HOME/sessions/$RID/work/src/server.go
# pid 1 always exists, so the app shows this session as running.
setjson $MUDROOM_HOME/sessions/$RID status='"running"' runnerPID=1 started="\"$(ago 2M)\"" created="\"$(ago 2M)\""

echo "demo store: $MUDROOM_HOME"
echo "review session: $ID"

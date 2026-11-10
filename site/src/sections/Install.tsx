import { useState } from "react"
import { LuLaptop, LuMonitorSmartphone, LuExternalLink, LuSmartphone } from "react-icons/lu"
import { Section } from "@/components/Section"
import { RELEASES, REPO } from "@/lib/site"
import { cn } from "@/lib/utils"

type Step = { title: string; body: React.ReactNode }

const code = (t: string) => <code className="rounded-md bg-white/[0.06] px-1.5 py-0.5 font-mono text-[13px] text-white/80">{t}</code>
const link = (href: string, t: string) => (
  <a href={href} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-accent-soft underline-offset-4 hover:underline">{t}<LuExternalLink className="h-3 w-3" /></a>
)

const noMac: Step[] = [
  { title: "Download the app file", body: <>Download {code("NoBars-unsigned.ipa")} from the {link(RELEASES, "latest release")} on GitHub.</> },
  { title: "Install Sideloadly", body: <>Get {link("https://sideloadly.io", "Sideloadly")} for Windows or macOS (AltStore works too). Plug in your iPhone with a cable.</> },
  { title: "Sign and install", body: <>Drop the {code(".ipa")} into Sideloadly, sign in with your Apple ID and hit Start. Your Apple ID is only used to sign the app for your own phone.</> },
  { title: "Trust it on your iPhone", body: <>Go to <b className="text-white/80">Settings › General › VPN &amp; Device Management</b> and trust your Apple ID. With a free Apple ID you'll need to reinstall every 7 days.</> },
]

const android: Step[] = [
  { title: "Download the APK", body: <>On your Android phone, download {code("NoBars.apk")} from the {link(RELEASES, "latest release")} on GitHub.</> },
  { title: "Install it", body: <>Open the file. If Android asks, allow your browser to install unknown apps, then tap Install.</> },
  { title: "Allow access", body: <>Allow <b className="text-white/80">Nearby devices</b>, <b className="text-white/80">Location</b> and <b className="text-white/80">Notifications</b>. A "mesh is live" notification means it's running.</> },
  { title: "Keep it running", body: <>Some phones close background apps. In NoBars' app info, set battery usage to <b className="text-white/80">Unrestricted</b> so it keeps relaying in your pocket.</> },
]

const mac: Step[] = [
  { title: "Get Xcode 26", body: <>Install Xcode 26 or newer from the Mac App Store.</> },
  { title: "Clone and open", body: <>{code(`git clone ${REPO}.git`)} then open {code("NoBars.xcodeproj")}.</> },
  { title: "Set your team", body: <>Under <b className="text-white/80">Signing &amp; Capabilities</b>, pick your team for both the app and widget targets. If the bundle ID is taken, change it to something unique.</> },
  { title: "Run on your iPhone", body: <>Plug in your phone, pick it as the destination and press Run. On a free Apple ID, remove the App Groups capability; only the widget needs it.</> },
]

const firstRun: Step[] = [
  { title: "Install on 2+ phones", body: "Any mix of iPhones and Android phones. Three or more lets you see multi-hop relaying in action." },
  { title: "Same group code", body: "Open NoBars on each phone, enter a name and the same group code (anything, like fest24)." },
  { title: "Allow access", body: "On iPhone allow Local Network, Bluetooth, Location, Microphone and Notifications. On Android allow Nearby devices, Location and Notifications." },
  { title: "Go offline", body: "Turn off Mobile Data and disconnect from Wi-Fi, keeping Bluetooth on. Your crew shows up in seconds." },
]

function Steps({ steps }: { steps: Step[] }) {
  return (
    <ol className="grid gap-3 sm:grid-cols-2">
      {steps.map((s, i) => (
        <li key={s.title} className="reveal rounded-2xl border border-line bg-surface p-5">
          <div className="flex items-center gap-3">
            <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-accent/15 font-mono text-[13px] font-semibold text-accent-soft">{i + 1}</span>
            <h4 className="text-[16px] font-semibold tracking-tight">{s.title}</h4>
          </div>
          <p className="mt-3 text-[15px] leading-relaxed text-white/55">{s.body}</p>
        </li>
      ))}
    </ol>
  )
}

export function Install() {
  const [tab, setTab] = useState<"android" | "pc" | "mac">("android")
  return (
    <Section id="install" eyebrow="Install" title="Get it on your phone."
      intro="NoBars isn't in the app stores yet, so you install it yourself. On Android it's one file. On iPhone it takes about ten minutes, and you don't need a Mac.">
      <div className="reveal inline-flex rounded-full border border-line bg-surface p-1">
        {([["android", "Android", LuSmartphone], ["pc", "iPhone", LuMonitorSmartphone], ["mac", "iPhone + Mac", LuLaptop]] as const).map(([k, l, Icon]) => (
          <button key={k} onClick={() => setTab(k)}
            className={cn("flex items-center gap-2 rounded-full px-4 py-2 text-[14px] font-medium transition",
              tab === k ? "bg-white text-black" : "text-white/60 hover:text-white")}>
            <Icon className="h-4 w-4" /> {l}
          </button>
        ))}
      </div>
      <div className="mt-6"><Steps steps={tab === "android" ? android : tab === "pc" ? noMac : mac} /></div>

      <h3 className="reveal mt-12 text-[22px] font-semibold tracking-tight">Then, first run</h3>
      <div className="mt-6"><Steps steps={firstRun} /></div>
    </Section>
  )
}

import type { IconType } from "react-icons"
import { LuMessagesSquare, LuInbox, LuSiren, LuCompass, LuPhoneCall, LuLock, LuRefreshCw, LuSmartphoneNfc, LuUserX, LuMoon, LuSmartphone } from "react-icons/lu"
import SpotlightCard from "@/components/SpotlightCard"
import { Section } from "@/components/Section"

const features: { icon: IconType; title: string; body: string; wide?: boolean }[] = [
  { icon: LuMessagesSquare, title: "Multi-hop chat", body: "Group chat that hops phone to phone across the crowd, so it reaches people well outside your own range.", wide: true },
  { icon: LuInbox, title: "Store and forward", body: "Send with nobody around. It's queued and delivered the moment a buddy comes into range." },
  { icon: LuCompass, title: "Map and compass", body: "See where your crew is and get a compass arrow with the distance to each buddy." },
  { icon: LuPhoneCall, title: "Calls, even out of range", body: "Voice and video with buddies nearby. Further away, the call hops through other phones. No servers, no WebRTC." },
  { icon: LuLock, title: "Private groups", body: "Pick a group code. It never gets broadcast. Everything is encrypted with it and signed per phone, so nobody can read along or fake an SOS." },
  { icon: LuSiren, title: "One-tap SOS", body: "Floods your live location to the whole group every few seconds, even with the screen locked. Everyone gets an alert and a red pin.", wide: true },
  { icon: LuSmartphoneNfc, title: "Lives on your iPhone", body: "Live Activity and Dynamic Island, a home screen widget, a Control Center SOS button, and Siri shortcuts.", wide: true },
  { icon: LuMoon, title: "Keeps going in your pocket", body: "Lock the phone and it keeps relaying chat and SOS over Bluetooth, and tells you when something arrives." },
  { icon: LuSmartphone, title: "iPhone and Android", body: "An Android app speaks the same protocol, so the whole crew meshes together whatever phone they carry." },
  { icon: LuRefreshCw, title: "Auto reconnect", body: "Walk out of range and come back. NoBars finds your buddy again on its own." },
  { icon: LuUserX, title: "No account", body: "No sign-up, no phone number. Pick a name and you're on." },
]

export function Features() {
  return (
    <Section id="features" eyebrow="Features" title="Everything still works at zero bars."
      intro="Built for places where networks fall over: packed concerts, festivals, treks, campus basements and disaster zones.">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {features.map(f => (
          <SpotlightCard key={f.title} spotlightColor="rgba(133, 90, 255, 0.18)" theme="dark" intensity={0.6} borderGlow={0.35}
            className={`reveal !rounded-3xl !border-line !bg-surface p-6 ${f.wide ? "lg:col-span-2" : ""}`}>
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-accent/15 text-accent-soft">
              <f.icon className="h-5 w-5" />
            </div>
            <h3 className="mt-5 text-[17px] font-semibold tracking-tight">{f.title}</h3>
            <p className="mt-2 text-[15px] leading-relaxed text-white/55">{f.body}</p>
          </SpotlightCard>
        ))}
      </div>
    </Section>
  )
}

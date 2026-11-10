import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion"
import { Section } from "@/components/Section"

const faqs = [
  ["Will it work on Android?", "Not yet. NoBars is built on Apple's own peer-to-peer networking, which only exists on iPhone. An Android version is planned, and it'll ship later as a proper release. Android and iPhone phones can't mesh together in this version."],
  ["Is it on the App Store?", "Not yet. Right now you install it yourself with Sideloadly or Xcode (steps above). An App Store release is the goal once it's been tested properly on real crowds."],
  ["Does it really need no internet?", "Yes. Phones talk directly over Bluetooth and peer-to-peer Wi-Fi. No cell towers, no Wi-Fi router, no servers. Turn on airplane mode, then switch Bluetooth and Wi-Fi back on, and it still works."],
  ["How far does it reach?", "Roughly 10 to 30 metres per phone over Bluetooth, more over peer-to-peer Wi-Fi, depending on walls and crowds. Each extra phone in between extends the reach, up to 10 hops."],
  ["Do I need to keep the app open?", "For the mesh to relay, yes. iOS pauses peer-to-peer connections in the background. SOS location sharing keeps running with the screen locked, but it only reaches people while you're connected."],
  ["Can I call someone far away through the mesh?", "Not yet. Voice and video calls work with anyone you're directly connected to. Chat, location and SOS travel across multiple hops."],
  ["Is it private?", "Your group code never leaves your phone. Every message, location and SOS is encrypted with a key made from it and signed by the phone that sent it, so outsiders can't read anything and nobody can post under your name. Nothing goes through a server, because there isn't one. Use a long code for anything private, or leave it blank to join the open mesh."],
  ["Does it drain my battery?", "Less than streaming video. Bluetooth and Wi-Fi radios stay active while the app is open, and SOS uses GPS, so expect more drain than usual during long sessions."],
  ["Does it cost anything?", "No. It's free, and the code is public on GitHub."],
]

export function Faq() {
  return (
    <Section id="faq" eyebrow="FAQ" title="Honest answers.">
      <Accordion type="single" collapsible className="reveal max-w-3xl">
        {faqs.map(([q, a]) => (
          <AccordionItem key={q} value={q} className="border-line">
            <AccordionTrigger className="py-5 text-left text-[17px] font-medium hover:no-underline">{q}</AccordionTrigger>
            <AccordionContent className="pb-5 text-[15px] leading-relaxed text-white/55">{a}</AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </Section>
  )
}

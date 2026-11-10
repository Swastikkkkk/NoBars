import { useRef } from "react"
import gsap from "gsap"
import { useGSAP } from "@gsap/react"
import { LuArrowDown, LuGithub } from "react-icons/lu"
import SplitText from "@/components/SplitText"
import { Phone } from "@/components/Phone"
import { REPO, asset } from "@/lib/site"

export function Hero() {
  const root = useRef<HTMLDivElement>(null)
  useGSAP(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    gsap.from(".hero-fade", { y: 18, opacity: 0, duration: 0.9, ease: "power3.out", stagger: 0.12, delay: 0.5 })
    gsap.from(".hero-phone", { y: 60, opacity: 0, duration: 1.4, ease: "expo.out", delay: 0.3 })
    gsap.to(".hero-phone", {
      yPercent: -8,
      rotate: 2,
      ease: "none",
      scrollTrigger: { trigger: root.current, start: "top top", end: "bottom top", scrub: 1.4 },
    })
    gsap.utils.toArray<HTMLElement>(".ring").forEach((el, i) => {
      gsap.fromTo(el, { scale: 0.55, opacity: 0.5 }, { scale: 1.5, opacity: 0, duration: 4.5, ease: "none", repeat: -1, delay: i * 1.5 })
    })
  }, { scope: root })

  return (
    <section id="top" ref={root} className="relative mx-auto grid max-w-6xl items-center gap-10 px-5 pb-12 pt-24 sm:px-8 lg:grid-cols-[1.1fr_0.9fr] lg:pt-28">
      <div>
        <SplitText
          text="Talk when there's no signal."
          tag="h1"
          className="mt-6 text-[48px] leading-[0.94] tracking-[-0.025em] text-white sm:text-[76px]"
          splitType="words"
          delay={70}
          duration={1}
          from={{ opacity: 0, y: 40 }}
          to={{ opacity: 1, y: 0 }}
          textAlign="left"
          trigger="load"
        />
        <p className="hero-fade mt-6 max-w-xl text-[18px] leading-relaxed text-white/60">
          NoBars links iPhones and Android phones over Bluetooth and peer-to-peer Wi-Fi into a mesh that passes messages from phone to phone.
          Chat, share live location, send SOS and call your crew with zero bars, no internet and no server.
        </p>
        <div className="hero-fade mt-7 flex flex-wrap items-center gap-3">
          <a href="#install" className="group flex items-center gap-2 rounded-full bg-accent px-5 py-3 text-[15px] font-medium text-white transition hover:bg-[#7548f5]">
            How to install <LuArrowDown className="h-4 w-4 transition group-hover:translate-y-0.5" />
          </a>
          <a href={REPO} target="_blank" rel="noreferrer" className="flex items-center gap-2 rounded-full border border-white/12 px-5 py-3 text-[15px] font-medium text-white/85 transition hover:bg-white/5">
            <LuGithub className="h-4 w-4" /> Source code
          </a>
        </div>
        <p className="hero-fade mt-6 text-[13px] text-white/40">iPhone (iOS 26+) and Android 10+ · Needs 2+ phones · Free and open source</p>
      </div>

      <div className="relative mx-auto flex h-[560px] w-full max-w-[420px] items-center justify-center sm:h-[640px]">
        {[0, 1, 2].map(i => (
          <div key={i} className="ring pointer-events-none absolute aspect-square w-[118%] rounded-full border border-accent/40" />
        ))}
        <Phone src={asset("shots/home.webp")} alt="NoBars home screen with one buddy connected" className="hero-phone relative w-[260px] sm:w-[290px]" />
      </div>
    </section>
  )
}

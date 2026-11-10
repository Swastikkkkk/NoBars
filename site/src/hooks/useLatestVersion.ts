import { useEffect, useState } from "react"

/** Tag of the newest GitHub release (e.g. "v1.0.1"), or null until it loads or if it fails. */
export function useLatestVersion() {
  const [version, setVersion] = useState<string | null>(null)
  useEffect(() => {
    fetch("https://api.github.com/repos/Swastikkkkk/NoBars/releases/latest")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d?.tag_name && setVersion(d.tag_name))
      .catch(() => {})
  }, [])
  return version
}

export const REPO = "https://github.com/Swastikkkkk/NoBars"
export const RELEASES = `${REPO}/releases/latest`
/** Always the newest release's files, so links never go stale. */
export const APK_URL = `${RELEASES}/download/NoBars.apk`
export const IPA_URL = `${RELEASES}/download/NoBars-unsigned.ipa`
export const asset = (p: string) => `${import.meta.env.BASE_URL}${p}`

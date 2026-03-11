export const sampleID = () => 'ID_' + Math.random().toString(36).substring(2, 10)

export const generateSecureKey = (bits = 256) => {
  const bytes = bits / 8
  const array = new Uint8Array(bytes)
  crypto.getRandomValues(array)
  return Array.from(array)
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

export function Contact() {
  const email = process.env.SUPPORT_EMAIL;
  return <p>For privacy questions or help with Smart Teleprompter, {email ? <a href={`mailto:${email}`}>contact {email}</a> : <>use the support link on the app’s App Store listing</>}.</p>;
}

import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import {SUPABASE_URL, SUPABASE_ANON_KEY} from './config.js';
const $ = id => document.getElementById(id);
const redirectTo = new URL('./auth.html', location.href).href.split(/[?#]/)[0];
const callback = new URLSearchParams(location.hash.slice(1));
const passwordCallback = ['invite', 'recovery'].includes(callback.get('type'));
let mode = passwordCallback ? 'password' : new URLSearchParams(location.search).get('mode') === 'signup' ? 'signup' : 'signin';
let client, busy = false;
const copy = {
  signin: ['Welcome back', 'Sign in to save your provider securely and keep your favorites with you.', 'Sign in'],
  signup: ['Make yourself at home', 'Create your account, then confirm your email to get started.', 'Create account'],
  reset: ['Reset your password', 'Enter your account email. We will send you a recovery link.', 'Send recovery email'],
  password: ['Choose a password', 'Set your password to finish your invitation or password recovery.', 'Save password'],
};
function status(message, error = false) {
  $('status').textContent = message;
  $('status').classList.toggle('error', error);
}
function setMode(next, focus = false) {
  mode = next;
  const newPassword = next === 'signup' || next === 'password';
  $('form').classList.remove('hidden');
  $('signedin').classList.add('hidden');
  $('links').classList.remove('hidden');
  $('emailrow').classList.toggle('hidden', next === 'password');
  $('email').required = next !== 'password';
  $('email').disabled = next === 'password';
  $('passwordrow').classList.toggle('hidden', next === 'reset');
  $('password').required = next !== 'reset';
  $('password').disabled = next === 'reset';
  $('password').minLength = newPassword ? 8 : 1;
  $('password').autocomplete = newPassword ? 'new-password' : 'current-password';
  $('password').value = '';
  $('password').type = 'password';
  $('togglePassword').textContent = 'Show';
  $('togglePassword').setAttribute('aria-label', 'Show password');
  $('togglePassword').setAttribute('aria-pressed', 'false');
  $('confirmrow').classList.toggle('hidden', !newPassword);
  $('confirm').required = newPassword;
  $('confirm').disabled = !newPassword;
  $('confirm').value = '';
  $('confirm').setCustomValidity('');
  $('passwordHint').classList.toggle('hidden', !newPassword);
  [$('title').textContent, $('description').textContent, $('submit').textContent] = copy[next];
  $('forgot').classList.toggle('hidden', next !== 'signin');
  $('signup').classList.toggle('hidden', next !== 'signin');
  $('back').classList.toggle('hidden', next === 'signin');
  $('resend').classList.add('hidden');
  status('');
  if (focus) $(next === 'password' ? 'password' : 'email').focus();
}
function setBusy(value) {
  busy = value;
  $('form').setAttribute('aria-busy', String(value));
  for (const id of ['submit', 'forgot', 'signup', 'back', 'resend', 'signout']) $(id).disabled = value || !client;
}
function showSession(session) {
  if (!session) return;
  $('password').value = '';
  $('confirm').value = '';
  $('form').classList.add('hidden');
  $('links').classList.add('hidden');
  $('signedin').classList.remove('hidden');
  $('identity').textContent = 'Signed in as ' + (session.user?.email || 'your account');
  $('title').textContent = 'You’re signed in';
  $('description').textContent = 'Connect your IPTV provider, save its password securely, and enjoy your channels.';
  status('');
}
function friendlyError(error) {
  if (error.code === 'signup_disabled') return 'Account registration is currently closed. Please contact the app owner.';
  if (error.code === 'email_not_confirmed') return 'Please confirm your email before signing in. You can resend the confirmation below.';
  if (error.code === 'invalid_credentials') return 'That email and password did not match. Try again or reset your password.';
  if (error.status === 429 || /rate.limit/i.test(error.code || '')) return 'Too many attempts. Please wait a few minutes and try again.';
  return error.message || 'Unable to continue. Please try again.';
}
$('forgot').onclick = () => !busy && setMode('reset', true);
$('signup').onclick = () => !busy && setMode('signup', true);
$('back').onclick = () => !busy && setMode('signin', true);
$('togglePassword').onclick = () => {
  const reveal = $('password').type === 'password';
  $('password').type = reveal ? 'text' : 'password';
  $('togglePassword').textContent = reveal ? 'Hide' : 'Show';
  $('togglePassword').setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
  $('togglePassword').setAttribute('aria-pressed', String(reveal));
};
const validateConfirmation = () => $('confirm').setCustomValidity($('confirm').required && $('confirm').value !== $('password').value ? 'Passwords must match.' : '');
$('confirm').oninput = validateConfirmation;
$('password').oninput = validateConfirmation;
$('signout').onclick = async () => {
  if (!client || busy) return;
  setBusy(true);
  try { const {error} = await client.auth.signOut(); if (error) throw error; setMode('signin'); }
  catch (error) { status(friendlyError(error), true); }
  finally { setBusy(false); }
};
$('resend').onclick = async () => {
  if (!client || busy) return;
  if (!$('email').reportValidity()) return;
  setBusy(true);
  try {
    const {error} = await client.auth.resend({type: 'signup', email: $('email').value.trim(), options: {emailRedirectTo: redirectTo}});
    if (error) throw error;
    status('If your account needs confirmation, a new link has been sent. Check your inbox and spam folder.');
  } catch (error) { status(friendlyError(error), true); }
  finally { setBusy(false); }
};
$('form').onsubmit = async event => {
  event.preventDefault();
  if (!client || busy) return;
  validateConfirmation();
  if (!$('form').reportValidity()) return;
  const submittedMode = mode;
  setBusy(true);
  status('Please wait…');
  try {
    const email = $('email').value.trim(), password = $('password').value;
    let result;
    if (submittedMode === 'signin') result = await client.auth.signInWithPassword({email, password});
    else if (submittedMode === 'signup') result = await client.auth.signUp({email, password, options: {emailRedirectTo: redirectTo}});
    else if (submittedMode === 'reset') result = await client.auth.resetPasswordForEmail(email, {redirectTo});
    else result = await client.auth.updateUser({password});
    if (result.error) throw result.error;
    if (submittedMode === 'reset') status('If that account exists, a recovery email has been sent. Check your inbox and spam folder.');
    else if (submittedMode === 'password') { showSession({user: result.data.user}); status('Password saved. You can open Rigatoni Stream.'); }
    else if (result.data.session) showSession(result.data.session);
    else {
      setMode('signin');
      $('resend').classList.remove('hidden');
      status('Check your email for a confirmation link, then return here to sign in. If you already have an account, sign in or reset your password.');
    }
  } catch (error) {
    status(friendlyError(error), true);
    if (error.code === 'email_not_confirmed') $('resend').classList.remove('hidden');
  } finally { setBusy(false); }
};
setMode(mode);
try {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || SUPABASE_URL.includes('YOUR_') || SUPABASE_ANON_KEY.includes('YOUR_')) throw new Error('Account setup is incomplete. Please contact the app owner.');
  client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {auth: {persistSession: true, autoRefreshToken: true, detectSessionInUrl: true}});
  client.auth.onAuthStateChange((event, session) => {
    if (event === 'PASSWORD_RECOVERY') setMode('password');
    else if ((event === 'SIGNED_IN' || event === 'INITIAL_SESSION') && session && mode !== 'password') showSession(session);
    else if (event === 'SIGNED_OUT') setMode('signin');
  });
  const {data: {session}, error} = await client.auth.getSession();
  if (error) throw error;
  if (callback.get('error_description')) status(callback.get('error_description') + ' Request a new link or try signing in.', true);
  else if (session && !passwordCallback && mode !== 'password') showSession(session);
  else if (passwordCallback && !session) { setMode('reset'); status('This link has expired or is invalid. Request a new recovery link.', true); }
  setBusy(false);
} catch (error) { status(friendlyError(error), true); client = undefined; setBusy(false); }

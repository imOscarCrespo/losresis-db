DROP TRIGGER IF EXISTS send_push_notifications ON public.notifications;

CREATE TRIGGER send_push_notifications
AFTER INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION supabase_functions.http_request(
  'https://chgretwxywvaaruwovbb.supabase.co/functions/v1/send-push-notifications',
  'POST',
  '{"Content-type":"application/json"}',
  '{}',
  '5000'
);

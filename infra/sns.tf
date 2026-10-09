# El destino del diagnóstico. Separado del topic de alertas del pipeline a
# propósito: el agente solo puede publicar aquí.
resource "aws_sns_topic" "diagnosis" {
  name = "demo-agent-diagnosis"
}

# Llega un correo "AWS Notification - Subscription Confirmation": confirmarlo
# ANTES de la primera corrida o el diagnóstico no llega.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.diagnosis.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

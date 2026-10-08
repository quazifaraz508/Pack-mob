from django.urls import path
from .views import OCRView, WebhookView

urlpatterns = [
    path('ocr/', OCRView.as_view(), name='ocr'),
    path('webhook/', WebhookView.as_view(), name='webhook'),
]

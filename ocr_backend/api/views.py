import requests
import time
import os
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.parsers import MultiPartParser
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync

class OCRView(APIView):
    parser_classes = [MultiPartParser]

    def post(self, request, format=None):
        print("FILES:", request.FILES)
        print("POST:", request.POST)
        print("DATA:", request.data)
        file_obj = request.FILES.get('image')
        if not file_obj:
            return Response({'error': 'No image provided', 'received_files': list(request.FILES.keys())}, status=400)


        api_key = os.environ.get("DATALAB_API_KEY")
        if not api_key:
            return Response({'error': 'DATALAB_API_KEY not configured on server'}, status=500)
            
        headers = {
            "X-API-Key": api_key
        }

        # Ensure the filename has a valid extension for Datalab
        file_name = file_obj.name
        if not any(file_name.lower().endswith(ext) for ext in ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.pdf']):
            file_name = 'image.jpg'

        # Submit the file to Datalab convert API
        submit_url = "https://www.datalab.to/api/v1/convert"
        
        # Datalab expects the correct content type and extension
        content_type = file_obj.content_type
        if content_type == 'application/octet-stream':
            content_type = 'image/jpeg'
            
        files = {
            'file': (file_name, file_obj.read(), content_type)
        }
        
        # We can also pass model configuration if needed
        data = {
            # 'model': 'chandra' # if required
        }

        submit_resp = requests.post(submit_url, headers=headers, files=files, data=data)
        if submit_resp.status_code != 200:
            return Response({'error': f'Datalab submission failed: {submit_resp.text}'}, status=submit_resp.status_code)

        resp_json = submit_resp.json()
        request_id = resp_json.get('request_id')

        if not request_id:
            return Response({'error': 'No request_id returned from Datalab'}, status=500)

        # Return the request_id immediately. The client will open a WebSocket using this ID to listen for the result.
        return Response({
            'status': 'processing',
            'request_id': request_id,
            'message': 'Image submitted successfully. Connect to WebSocket to receive results.'
        })

class WebhookView(APIView):
    def post(self, request, *args, **kwargs):
        payload = request.data
        request_id = payload.get('request_id')
        webhook_secret = payload.get('webhook_secret')
        
        # 1. Verify the Webhook Secret
        expected_secret = os.environ.get('DATALAB_WEBHOOK_SECRET')
        if not expected_secret or webhook_secret != expected_secret:
            print(f"Webhook rejected: Invalid secret. Expected {expected_secret}, got {webhook_secret}")
            return Response({'error': 'Invalid webhook_secret'}, status=403)
        
        if not request_id:
            print("Webhook received with no request_id in payload:", payload)
            return Response({'status': 'ignored, no request_id'})
            
        # 2. The webhook doesn't contain the OCR data, just a notification that it's done.
        # We must fetch the actual result from Datalab.
        api_key = os.environ.get("DATALAB_API_KEY")
        headers = {"X-API-Key": api_key}
        # We can use the provided request_check_url or fallback to the convert endpoint
        check_url = payload.get('request_check_url', f"https://www.datalab.to/api/v1/convert/{request_id}")
        
        try:
            resp = requests.get(check_url, headers=headers)
            if resp.status_code == 200:
                poll_json = resp.json()
                status = poll_json.get('status')
                
                if status in ['complete', 'completed', 'finished', 'success', 'done']:
                    data = poll_json.get('markdown') or poll_json.get('result') or poll_json.get('output') or poll_json
                    msg = {'status': 'success', 'data': data}
                else:
                    msg = {'error': f"OCR status is {status}, but webhook fired."}
            else:
                msg = {'error': f"Failed to fetch final result from Datalab: {resp.text}"}
        except Exception as e:
            msg = {'error': f"Error fetching result: {str(e)}"}
            
        # 3. Send to the WebSocket consumer waiting for this request_id
        channel_layer = get_channel_layer()
        async_to_sync(channel_layer.group_send)(
            f'ocr_{request_id}',
            {
                'type': 'ocr_result',
                'data': msg
            }
        )
        
        return Response({'status': 'ok'})

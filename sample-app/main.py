import boto3

session = boto3.Session(profile_name='S3ReadOnlyAccess')
client = session.client('s3')

response = client.list_buckets()
for _bucket in response['Buckets']:
    print(_bucket['Name'])
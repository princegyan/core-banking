import { IsString, IsNotEmpty, IsOptional, IsEnum, IsUUID, IsObject } from 'class-validator';

export class QueueNotificationDto {
  @IsString()
  @IsNotEmpty()
  templateCode: string;

  @IsEnum(['SMS', 'EMAIL', 'PUSH', 'IN_APP'])
  @IsNotEmpty()
  channel: string;

  @IsEnum(['CUSTOMER', 'USER'])
  @IsNotEmpty()
  recipientType: string;

  @IsUUID()
  @IsNotEmpty()
  recipientId: string;

  @IsString()
  @IsNotEmpty()
  recipientAddress: string;

  @IsObject()
  @IsOptional()
  variables?: Record<string, any>;

  @IsString()
  @IsOptional()
  referenceType?: string;

  @IsUUID()
  @IsOptional()
  referenceId?: string;

  @IsEnum(['LOW', 'NORMAL', 'HIGH', 'URGENT'])
  @IsOptional()
  priority?: string;
}

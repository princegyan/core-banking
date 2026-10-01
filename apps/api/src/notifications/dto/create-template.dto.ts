import { IsString, IsNotEmpty, IsOptional, IsBoolean, IsEnum, IsArray } from 'class-validator';

export class CreateTemplateDto {
  @IsString()
  @IsNotEmpty()
  code: string;

  @IsString()
  @IsNotEmpty()
  name: string;

  @IsEnum(['SMS', 'EMAIL', 'PUSH', 'IN_APP'])
  @IsNotEmpty()
  channel: string;

  @IsString()
  @IsOptional()
  subject?: string;

  @IsString()
  @IsNotEmpty()
  bodyTemplate: string;

  @IsArray()
  @IsOptional()
  variables?: string[];

  @IsEnum(['DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'LOAN_DISBURSEMENT', 'LOAN_REPAYMENT', 'LOAN_OVERDUE', 'APPROVAL_REQUIRED', 'APPROVAL_COMPLETED', 'ACCOUNT_OPENED', 'ACCOUNT_CLOSED', 'PASSWORD_CHANGE', 'LOGIN_ALERT'])
  @IsOptional()
  eventTrigger?: string;

  @IsBoolean()
  @IsOptional()
  isActive?: boolean;
}

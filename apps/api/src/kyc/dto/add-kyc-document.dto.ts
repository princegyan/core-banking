import { IsString, IsNotEmpty, IsUUID, IsOptional, IsDateString, IsEnum } from 'class-validator';

export enum KycDocumentType {
  NATIONAL_ID = 'NATIONAL_ID',
  PASSPORT = 'PASSPORT',
  DRIVERS_LICENSE = 'DRIVERS_LICENSE',
  VOTERS_ID = 'VOTERS_ID',
  UTILITY_BILL = 'UTILITY_BILL',
  BANK_STATEMENT = 'BANK_STATEMENT',
  TAX_CERTIFICATE = 'TAX_CERTIFICATE',
  COMPANY_REGISTRATION = 'COMPANY_REGISTRATION',
  OTHER = 'OTHER',
}

export class AddKycDocumentDto {
  @IsUUID()
  @IsNotEmpty()
  customerId: string;

  @IsEnum(KycDocumentType)
  @IsNotEmpty()
  documentType: KycDocumentType;

  @IsString()
  @IsOptional()
  documentNumber?: string;

  @IsString()
  @IsOptional()
  filePath?: string;

  @IsString()
  @IsOptional()
  fileName?: string;

  @IsDateString()
  @IsOptional()
  issueDate?: string;

  @IsDateString()
  @IsOptional()
  expiryDate?: string;

  @IsString()
  @IsOptional()
  issuingAuthority?: string;
}

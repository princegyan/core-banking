import { IsBoolean, IsNotEmpty, IsOptional, IsString } from 'class-validator';

export class VerifyDocumentDto {
  @IsBoolean()
  @IsNotEmpty()
  approved: boolean;

  @IsString()
  @IsOptional()
  rejectionReason?: string;
}

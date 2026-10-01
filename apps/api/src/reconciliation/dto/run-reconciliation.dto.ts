import { IsOptional, IsString, IsUUID, IsNumber } from 'class-validator';

export class RunReconciliationDto {
  @IsOptional()
  @IsUUID()
  branchId?: string;
}

export class ResolveExceptionDto {
  @IsString()
  resolutionNotes: string;
}

export class CreateSuspenseDto {
  @IsNumber()
  amount: number;

  @IsString()
  currency: string;

  @IsString()
  reason: string;

  @IsOptional()
  @IsUUID()
  originalTransactionId?: string;
}

export class ClearSuspenseDto {
  @IsString()
  notes: string;
}

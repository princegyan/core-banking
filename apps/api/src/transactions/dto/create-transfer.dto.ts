import { IsInt, IsNotEmpty, IsOptional, IsUUID, Min } from 'class-validator';

export class CreateTransferDto {
  @IsUUID()
  sourceAccountId: string;

  @IsUUID()
  destinationAccountId: string;

  @IsInt()
  @Min(1)
  amount: number;

  @IsNotEmpty()
  description: string;

  @IsOptional()
  @IsNotEmpty()
  idempotencyKey?: string;
}
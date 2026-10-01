import { IsInt, IsNotEmpty, IsObject, IsOptional, IsString, Min } from 'class-validator';

export class CreatePlanDto {
  @IsString()
  @IsNotEmpty()
  planCode: string;

  @IsString()
  @IsNotEmpty()
  name: string;

  @IsString()
  @IsNotEmpty()
  tier: string;

  @IsInt()
  @Min(0)
  monthlyFee: number;

  @IsInt()
  @Min(1)
  maxAccounts: number;

  @IsInt()
  @Min(1)
  maxUsers: number;

  @IsInt()
  @Min(1)
  maxBranches: number;

  @IsInt()
  @Min(1)
  maxMonthlyTransactions: number;

  @IsObject()
  @IsOptional()
  features?: Record<string, any>;
}

import {
  IsBoolean,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  Min,
} from 'class-validator';

export class UpdateLoanProductDto {
  @IsString()
  @IsOptional()
  @MaxLength(150)
  name?: string;

  @IsString()
  @IsOptional()
  description?: string;

  @IsInt()
  @Min(0)
  @IsOptional()
  minimumPrincipal?: number;

  @IsInt()
  @Min(0)
  @IsOptional()
  maximumPrincipal?: number;

  @IsInt()
  @Min(0)
  @IsOptional()
  annualInterestRate?: number;

  @IsInt()
  @Min(1)
  @IsOptional()
  minimumTermDays?: number;

  @IsInt()
  @Min(1)
  @IsOptional()
  maximumTermDays?: number;

  @IsInt()
  @Min(0)
  @IsOptional()
  gracePeriodDays?: number;

  @IsBoolean()
  @IsOptional()
  gracePeriodInterest?: boolean;

  @IsInt()
  @Min(0)
  @IsOptional()
  penaltyRate?: number;

  @IsInt()
  @Min(0)
  @IsOptional()
  penaltyGraceDays?: number;

  @IsBoolean()
  @IsOptional()
  requiresCollateral?: boolean;

  @IsInt()
  @Min(0)
  @IsOptional()
  minimumCollateralRatio?: number;

  @IsBoolean()
  @IsOptional()
  requiresGuarantor?: boolean;

  @IsInt()
  @Min(0)
  @IsOptional()
  minimumGuarantors?: number;

  @IsBoolean()
  @IsOptional()
  allowPrepayment?: boolean;

  @IsInt()
  @Min(0)
  @IsOptional()
  prepaymentPenaltyRate?: number;

  @IsBoolean()
  @IsOptional()
  isActive?: boolean;
}

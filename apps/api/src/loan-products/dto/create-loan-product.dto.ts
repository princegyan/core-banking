import {
  IsBoolean,
  IsEnum,
  IsInt,
  IsNotEmpty,
  IsOptional,
  IsString,
  MaxLength,
  Min,
} from 'class-validator';

export enum LoanProductType {
  TERM_LOAN = 'TERM_LOAN',
  OVERDRAFT = 'OVERDRAFT',
  LINE_OF_CREDIT = 'LINE_OF_CREDIT',
  GROUP_LOAN = 'GROUP_LOAN',
  SALARY_ADVANCE = 'SALARY_ADVANCE',
}

export enum LoanInterestMethod {
  FLAT = 'FLAT',
  DECLINING_BALANCE = 'DECLINING_BALANCE',
}

export enum LoanInterestCalculationBasis {
  ACTUAL_365 = 'ACTUAL_365',
  ACTUAL_360 = 'ACTUAL_360',
  THIRTY_360 = 'THIRTY_360',
}

export enum LoanRepaymentFrequency {
  DAILY = 'DAILY',
  WEEKLY = 'WEEKLY',
  BIWEEKLY = 'BIWEEKLY',
  MONTHLY = 'MONTHLY',
  QUARTERLY = 'QUARTERLY',
  SEMI_ANNUALLY = 'SEMI_ANNUALLY',
  ANNUALLY = 'ANNUALLY',
}

export enum LoanAmortizationType {
  EQUAL_INSTALLMENTS = 'EQUAL_INSTALLMENTS',
  EQUAL_PRINCIPAL = 'EQUAL_PRINCIPAL',
  BULLET = 'BULLET',
  BALLOON = 'BALLOON',
}

export class CreateLoanProductDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(50)
  code: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(150)
  name: string;

  @IsString()
  @IsOptional()
  description?: string;

  @IsEnum(LoanProductType)
  productType: LoanProductType;

  @IsString()
  @IsNotEmpty()
  @MaxLength(3)
  currency: string;

  @IsInt()
  @Min(0)
  minimumPrincipal: number;

  @IsInt()
  @Min(0)
  maximumPrincipal: number;

  @IsInt()
  @Min(0)
  @IsOptional()
  defaultPrincipal?: number;

  @IsInt()
  @Min(0)
  annualInterestRate: number;

  @IsEnum(LoanInterestMethod)
  interestMethod: LoanInterestMethod;

  @IsEnum(LoanInterestCalculationBasis)
  interestCalculationBasis: LoanInterestCalculationBasis;

  @IsInt()
  @Min(1)
  minimumTermDays: number;

  @IsInt()
  @Min(1)
  maximumTermDays: number;

  @IsInt()
  @Min(1)
  @IsOptional()
  defaultTermDays?: number;

  @IsEnum(LoanRepaymentFrequency)
  repaymentFrequency: LoanRepaymentFrequency;

  @IsEnum(LoanAmortizationType)
  amortizationType: LoanAmortizationType;

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

  @IsInt()
  @Min(0)
  @IsOptional()
  balloonPercentage?: number;
}

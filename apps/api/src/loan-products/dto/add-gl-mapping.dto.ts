import {
  IsEnum,
  IsUUID,
} from 'class-validator';

export enum LoanGlMappingType {
  LOAN_PORTFOLIO = 'LOAN_PORTFOLIO',
  INTEREST_RECEIVABLE = 'INTEREST_RECEIVABLE',
  INTEREST_INCOME = 'INTEREST_INCOME',
  PENALTY_INCOME = 'PENALTY_INCOME',
  FUND_SOURCE = 'FUND_SOURCE',
  PROVISION_EXPENSE = 'PROVISION_EXPENSE',
  WRITE_OFF = 'WRITE_OFF',
  SUSPENSE = 'SUSPENSE',
}

export class AddGlMappingDto {
  @IsEnum(LoanGlMappingType)
  mappingType: LoanGlMappingType;

  @IsUUID()
  ledgerAccountId: string;
}
